#!/usr/bin/env python3
"""Add the open-source GB link library to a separate unencrypted sideload IPA.

Does not decrypt apps, sign/install apps, fetch apps, or modify the input IPA.
Uses Python 3 standard library only; Windows, Linux and macOS are supported.
"""
import argparse
import json
import pathlib
import plistlib
import struct
import zipfile

LOAD_PATH = "@executable_path/Frameworks/ManicGBLink.framework/ManicGBLink"
ARM64 = 0x0100000C


def inspect_slice(data):
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected a little-endian 64-bit Mach-O")
    _, cpu, subtype, filetype, count, command_size, _, _ = struct.unpack_from("<8I", data)
    if cpu != ARM64 or (subtype & 0xFFFFFF) != 0 or filetype not in (2, 6):
        raise ValueError("Only ordinary arm64 executables/libraries are supported; arm64e needs a matching build")
    end = 32 + command_size
    if count > 4096 or end > len(data):
        raise ValueError("Invalid Mach-O command table")
    offset, first_data, paths, encrypted, platform = 32, len(data), [], False, None
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError("Invalid load command size")
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError("Truncated segment")
            file_offset, file_size = struct.unpack_from("<QQ", data, offset + 40)
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            if size != 72 + sections * 80:
                raise ValueError("Invalid section table")
            if file_offset and file_size:
                first_data = min(first_data, file_offset)
            for i in range(sections):
                section = offset + 72 + i * 80
                section_size = struct.unpack_from("<Q", data, section + 40)[0]
                section_offset = struct.unpack_from("<I", data, section + 48)[0]
                flags = struct.unpack_from("<I", data, section + 64)[0]
                if section_size and section_offset and (flags & 0xFF) not in (1, 0xC, 0x12):
                    first_data = min(first_data, section_offset)
        elif command in (0x21, 0x2C):  # LC_ENCRYPTION_INFO / _64
            if size < 20:
                raise ValueError("Truncated encryption command")
            encrypted |= struct.unpack_from("<I", data, offset + 16)[0] != 0
        elif command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError("Truncated platform command")
            platform = struct.unpack_from("<I", data, offset + 8)[0]
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            platform = 2
        elif command in (0xC, 0x80000018, 0x8000001F):
            if size < 24:
                raise ValueError("Truncated dylib command")
            name = struct.unpack_from("<I", data, offset + 8)[0]
            if name < 24 or name >= size:
                raise ValueError("Invalid dylib path")
            path = data[offset + name:offset + size].split(b"\0", 1)[0].decode("utf-8")
            paths.append(path)
        offset += size
    if offset != end or first_data < end or first_data > len(data):
        raise ValueError("Overlapping or invalid Mach-O layout")
    return {"encrypted": encrypted, "load_paths": paths, "header_padding": first_data - end,
            "command_end": end, "commands": count, "command_size": command_size, "filetype": filetype,
            "platform": platform}


def patch_slice(data):
    info = inspect_slice(data)
    if info["encrypted"]:
        raise ValueError("Encrypted application: refused. Use an official unencrypted sideload/source-built IPA; no decryption is provided")
    if LOAD_PATH in info["load_paths"]:
        raise ValueError("GB Link already embedded; refusing to patch twice")
    path = LOAD_PATH.encode() + b"\0"
    size = (24 + len(path) + 7) & ~7
    end = info["command_end"]
    if info["header_padding"] < size or any(data[end:end + size]):
        raise ValueError(f"Insufficient empty Mach-O header padding (need {size} bytes). Rebuild with -headerpad or use a source build")
    out = bytearray(data)
    struct.pack_into("<6I", out, end, 0xC, size, 24, 0, 0, 0)
    out[end + 24:end + 24 + len(path)] = path
    struct.pack_into("<II", out, 16, info["commands"] + 1, info["command_size"] + size)
    return bytes(out)


def slices(data):
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        if count != 1 or len(data) < 28:
            raise ValueError("Universal IPA with multiple architectures needs a source build or per-architecture libraries")
        cpu, _, offset, size, _ = struct.unpack_from(">5I", data, 8)
        if cpu != ARM64 or offset < 28 or offset + size > len(data):
            raise ValueError("Invalid universal Mach-O")
        return offset, size
    return 0, len(data)


def patch_macho(data):
    offset, size = slices(data)
    return data[:offset] + patch_slice(data[offset:offset + size]) + data[offset + size:]


def checked_entries(archive):
    entries = archive.infolist()
    if len(entries) > 100000 or sum(i.file_size for i in entries) > 4 * 1024**3:
        raise ValueError("IPA exceeds packaging limits")
    names = set()
    for item in entries:
        name = item.filename
        # ZipInfo normalizes backslashes on Windows. Inspect the original
        # central-directory name too, so malformed input is rejected everywhere.
        raw_name = item.orig_filename
        parts = pathlib.PurePosixPath(raw_name).parts
        if not parts or raw_name.startswith("/") or "\\" in raw_name or ".." in parts or ":" in raw_name or name in names:
            raise ValueError("Unsafe or duplicate IPA entry")
        if item.flag_bits & 1 or ((item.external_attr >> 16) & 0o170000) == 0o120000:
            raise ValueError("Encrypted ZIP entries and symbolic links are unsupported")
        names.add(name)
    return entries


def app_info(archive):
    entries = checked_entries(archive)
    plists = [i.filename for i in entries if i.filename.startswith("Payload/")
              and i.filename.endswith(".app/Info.plist") and i.filename.count("/") == 2]
    if len(plists) != 1:
        raise ValueError("Expected exactly one top-level iOS app")
    path = plists[0]
    info = plistlib.loads(archive.read(path))
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable or executable in (".", ".."):
        raise ValueError("Invalid app executable name")
    binary_path = path.rsplit("/", 1)[0] + "/" + executable
    binary = archive.read(binary_path)
    offset, size = slices(binary)
    binary_info = inspect_slice(binary[offset:offset + size])
    if binary_info["filetype"] != 2:
        raise ValueError("Top-level app is not a Mach-O executable")
    return entries, path, info, binary_path, binary, binary_info


def repackage(source, framework, output):
    source, framework, output = pathlib.Path(source), pathlib.Path(framework), pathlib.Path(output)
    if source.resolve() == output.resolve() or output.exists():
        raise ValueError("Choose a new output path; input and existing outputs are preserved")
    if framework.name != "ManicGBLink.framework" or not (framework / "ManicGBLink").is_file():
        raise ValueError("Provide the built ManicGBLink.framework directory")
    library = (framework / "ManicGBLink").read_bytes()
    library_info = inspect_slice(library)
    if library_info["encrypted"] or library_info["filetype"] != 6:
        raise ValueError("Expected an unencrypted arm64 dynamic library")
    if library_info["platform"] != 2:
        raise ValueError("Framework is not built for physical iOS; simulator/macOS binaries cannot be embedded")
    framework_info = plistlib.loads((framework / 'Info.plist').read_bytes())
    if framework_info.get('CFBundleExecutable') != 'ManicGBLink' or framework_info.get('CFBundlePackageType') != 'FMWK':
        raise ValueError("Invalid framework Info.plist")
    with zipfile.ZipFile(source) as original:
        entries, plist_path, info, binary_path, binary, binary_info = app_info(original)
        if binary_info['platform'] != 2:
            raise ValueError("Input app is not built for physical iOS")
        patched = patch_macho(binary)  # Validate all blockers before creating output.
        info["MGLInjectGBLink"] = True
        original_min = tuple(int(n) for n in info.get('MinimumOSVersion', '0').split('.'))
        if original_min < (15,):
            info['MinimumOSVersion'] = '15.0'
        info["NSLocalNetworkUsageDescription"] = "Connect with your friend for local Game Boy link play."
        services = info.setdefault("NSBonjourServices", [])
        if not isinstance(services, list):
            raise ValueError("Invalid Bonjour service list")
        if "_manic-gblink._tcp" not in services:
            services.append("_manic-gblink._tcp")
        app = plist_path.rsplit("/", 1)[0]
        prefix = app + "/Frameworks/ManicGBLink.framework/"
        if any(i.filename.startswith(prefix) for i in entries):
            raise ValueError("Framework already present")
        files = sorted(p for p in framework.rglob("*") if p.is_file())
        if any(p.is_symlink() for p in framework.rglob("*")):
            raise ValueError("Framework symlinks are unsupported")
        with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as target:
            for item in entries:
                if "_CodeSignature" in pathlib.PurePosixPath(item.filename).parts:
                    continue  # Invalidated signatures are replaced by the user's signer.
                contents = patched if item.filename == binary_path else (
                    plistlib.dumps(info, fmt=plistlib.FMT_BINARY) if item.filename == plist_path else original.read(item))
                target.writestr(item, contents)
            for file in files:
                target.write(file, prefix + file.relative_to(framework).as_posix())
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--inspect", action="store_true", help="Read only: report architecture, encryption and header padding")
    parser.add_argument("--framework")
    parser.add_argument("--output")
    args = parser.parse_args()
    if args.inspect:
        with zipfile.ZipFile(args.ipa) as archive:
            _, _, info, executable, _, binary_info = app_info(archive)
            print(json.dumps({"bundle_id": info.get("CFBundleIdentifier"), "executable": executable,
                              "architecture": "arm64", **binary_info}, indent=2))
    else:
        if not args.framework or not args.output:
            parser.error("--framework and --output are required for repackaging")
        print(repackage(args.ipa, args.framework, args.output))
        print("UNSIGNED: re-sign the app and every embedded framework with your existing sideload tool. No device installation performed.")


if __name__ == "__main__":
    main()
