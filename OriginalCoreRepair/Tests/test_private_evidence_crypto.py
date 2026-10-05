"""Real OpenSSL evidence round-trip and refusal before plaintext on tampering."""
import json,os,pathlib,subprocess,sys,tempfile,unittest,zipfile
from open_private_replay_evidence import open_evidence
class Evidence(unittest.TestCase):
    def test_roundtrip_and_tamper(self):
        with tempfile.TemporaryDirectory(prefix='azahar-synthetic-evidence-') as tmp:
            base=pathlib.Path(tmp);root=base/'azahar-private-house';data=root/'case/native-data';data.mkdir(parents=True)
            marker='SYNTHETIC_PRIVATE_MARKER_NOT_REAL_USER_DATA'
            (data/'core-runtime.log').write_text(marker)
            (data/'game-probe.json').write_text(json.dumps({'stage':'completed','run_calls':12,'error':marker,'loaded_images':[marker]}))
            (root/'exit-status.txt').write_text('0')
            password='synthetic-only-regression-password-123456789'
            env=os.environ.copy();env['RUNNER_TEMP']=tmp;env['PRIVATE_INPUTS']=json.dumps({'evidence_password':password})
            result=subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('private_house_ci.py')),'seal'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr);self.assertNotIn(marker,result.stdout)
            summary=(root/'deliverables/sanitized-summary.json').read_text();self.assertNotIn(marker,summary)
            cipher=root/'deliverables/private-evidence.authenticated.enc';original=cipher.read_bytes()
            output=base/'decrypted.zip';open_evidence(cipher,output,password)
            with zipfile.ZipFile(output) as z:
                self.assertEqual(z.read('case/native-data/core-runtime.log').decode(),marker)
                self.assertFalse(any('game.cxi' in n or 'garden_plus.dat' in n or '.3gx' in n for n in z.namelist()))
            with self.assertRaises(ValueError):open_evidence(cipher,base/'wrong-password.zip','wrong-password')
            self.assertFalse((base/'wrong-password.zip').exists())
            altered=bytearray(original);altered[-40]^=1;bad=base/'tampered.enc';bad.write_bytes(altered)
            with self.assertRaises(ValueError):open_evidence(bad,base/'tampered.zip',password)
            self.assertFalse((base/'tampered.zip').exists());self.assertEqual(original,cipher.read_bytes())
if __name__=='__main__':unittest.main()
