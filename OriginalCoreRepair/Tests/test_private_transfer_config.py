"""Validate approved transfer scope without reading real credentials or URLs."""
import copy,json,os,unittest
from unittest.mock import patch
from private_house_ci import config

class Transfers(unittest.TestCase):
    def setup_data(self):
        base={'parts':[{'bytes':400000000,'sha256':'1'*64,'url':'old-private-url'} for _ in range(2)]+
            [{'bytes':131274752,'sha256':'2'*64,'url':'old-private-url'}],
            'plugin':{'bytes':912559,'sha256':'3'*64,'url':'old-private-url'},
            'game_sha256':'4'*64,'evidence_password':'synthetic-secret-not-real'}
        refs=[f'synthetic-reference-{i}' for i in range(5)]
        names=['private-manic-game.part1','private-manic-game.part2','private-manic-game.part3',
               'private-manic-plugin.zip','azahar-house-replay-temporary-save.zip']
        sizes=[400000000,400000000,131274752,912559,2293576]
        fresh={'approved_library_ids':refs,'save_sha256':'5'*64,'transfers':[
            {'library_file_id':ref,'file_name':name,'size_bytes':size,'download_url':'synthetic-refreshed-url'}
            for ref,name,size in zip(refs,names,sizes)]}
        return base,fresh
    def parse(self,base,fresh):
        with patch.dict(os.environ,{'PRIVATE_INPUTS':json.dumps(base),'PRIVATE_HOUSE_TRANSFERS':json.dumps(fresh)}):return config()
    def test_preserves_existing_identity_and_credential(self):
        base,fresh=self.setup_data();old=copy.deepcopy(base);result=self.parse(base,fresh)
        self.assertEqual(base,old);self.assertEqual(result['evidence_password'],base['evidence_password'])
        self.assertEqual(result['game_sha256'],base['game_sha256'])
        self.assertEqual([i['sha256'] for i in result['parts']],[i['sha256'] for i in base['parts']])
        self.assertEqual(result['save']['sha256'],fresh['save_sha256'])
    def test_extra_transfer_refused(self):
        base,fresh=self.setup_data();fresh['transfers'].append(copy.deepcopy(fresh['transfers'][0]))
        with self.assertRaises(RuntimeError):self.parse(base,fresh)
    def test_duplicate_identity_refused(self):
        base,fresh=self.setup_data();fresh['transfers'][4]['library_file_id']=fresh['transfers'][0]['library_file_id']
        with self.assertRaises(RuntimeError):self.parse(base,fresh)
    def test_changed_existing_part_size_refused(self):
        base,fresh=self.setup_data();fresh['transfers'][0]['size_bytes']+=1
        with self.assertRaises(RuntimeError):self.parse(base,fresh)
    def test_unapproved_save_identity_refused(self):
        base,fresh=self.setup_data();fresh['transfers'][4]['library_file_id']='unapproved-ref'
        with self.assertRaises(RuntimeError):self.parse(base,fresh)
if __name__=='__main__':unittest.main()
