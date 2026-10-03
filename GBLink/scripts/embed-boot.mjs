import {readFileSync, writeFileSync} from 'node:fs';
const data = readFileSync(process.argv[2]);
if (data.length !== 256) throw new Error('Expected 256-byte open-source DMG bootstrap');
writeFileSync(process.argv[3], `// Generated from SameBoy's Expat-licensed DMG bootstrap.\nstatic const unsigned char mgl_dmg_boot[256] = {${[...data].join(',')}};\n`);
