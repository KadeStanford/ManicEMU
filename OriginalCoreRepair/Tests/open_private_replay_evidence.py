"""Authenticate an approved local replay artifact before decrypting to a NEW ZIP."""
import argparse,hashlib,hmac,os,pathlib,subprocess,tempfile
MAGIC=b'AZAHAR-EVIDENCE-HMAC-V1\0'
def open_evidence(source,output,password):
    if output.exists() or output.resolve()==source.resolve():raise ValueError('Exclusive new plaintext output required')
    original=source.read_bytes()
    if len(original)<len(MAGIC)+16+32 or not original.startswith(MAGIC):raise ValueError('Unknown envelope')
    body,tag=original[:-32],original[-32:];salt=body[len(MAGIC):len(MAGIC)+16]
    key=hashlib.pbkdf2_hmac('sha256',password.encode(),salt,200000,32)
    if not hmac.compare_digest(tag,hmac.digest(key,body,'sha256')):raise ValueError('Evidence authentication failed')
    env=os.environ.copy();env['AZAHAR_EVIDENCE_PASSWORD']=password
    with tempfile.TemporaryDirectory(prefix='azahar-authenticated-decryption-') as tmp:
        cipher=pathlib.Path(tmp)/'cipher';plain=pathlib.Path(tmp)/'plain'
        cipher.write_bytes(body[len(MAGIC)+16:])
        result=subprocess.run(['openssl','enc','-d','-aes-256-cbc','-pbkdf2','-iter','200000',
            '-pass','env:AZAHAR_EVIDENCE_PASSWORD','-in',str(cipher),'-out',str(plain)],env=env,capture_output=True)
        if result.returncode:raise RuntimeError('Evidence decryption failed; output suppressed')
        with plain.open('rb') as src,output.open('xb') as dst:
            while chunk:=src.read(4*1024*1024):dst.write(chunk)
    if source.read_bytes()!=original:raise ValueError('Encrypted original changed')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=pathlib.Path,required=True)
    p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    open_evidence(a.input,a.output,os.environ['AZAHAR_EVIDENCE_PASSWORD'])
    print('Evidence authenticated and decrypted locally; original ciphertext preserved')
