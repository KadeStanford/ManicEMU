"""Reject malformed/private save paths before creating any execution sandbox."""
import pathlib,stat,tempfile,unittest,zipfile
from stage_private_replay import read_save,TITLE,SAVE_NAMES

class SaveSafety(unittest.TestCase):
    def inspect(self,extra=None,missing=None):
        with tempfile.TemporaryDirectory(prefix='azahar-save-validation-') as tmp:
            path=pathlib.Path(tmp)/'copy.zip'
            with zipfile.ZipFile(path,'w') as z:
                for name in sorted(SAVE_NAMES-{missing}):z.writestr(TITLE+name,b'test normal save bytes')
                if extra:z.writestr(*extra)
            original=path.read_bytes()
            try:return read_save(path)
            finally:self.assertEqual(original,path.read_bytes())
    def test_complete_title_save(self):self.assertEqual(len(self.inspect()),5)
    def test_traversal(self):
        with self.assertRaises(ValueError):self.inspect(('../live-save.dat',b'bad'))
    def test_other_title(self):
        with self.assertRaises(ValueError):self.inspect((TITLE.replace('00198e00','00198d00')+'garden_plus.dat',b'bad'))
    def test_windows_separator(self):
        with self.assertRaises(ValueError):self.inspect((TITLE.replace('/','\\')+'extra.dat',b'bad'))
    def test_symlink(self):
        item=zipfile.ZipInfo(TITLE+'garden_plus.dat');item.create_system=3;item.external_attr=(stat.S_IFLNK|0o777)<<16
        with self.assertRaises(ValueError):self.inspect((item,b'../../../live-save'),missing='garden_plus.dat')
    def test_incomplete(self):
        with self.assertRaises(ValueError):self.inspect(missing='garden_plus.dat')

if __name__=='__main__':unittest.main()
