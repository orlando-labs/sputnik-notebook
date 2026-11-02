#!/usr/bin/env python3
"""Pure shared-worker managed-media transactions; no evaluator or web fixture."""
import base64, hashlib, json, pathlib, struct, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKER = ROOT / 'build/sputnik-notebook-worker'
with tempfile.TemporaryDirectory(prefix='sputnik-media-') as temporary:
    root = pathlib.Path(temporary)
    book = root / 'book'; book.mkdir()
    document = {'format':'sputnik-notebook','version':4,'title':'Media', 'active_sheet':'main',
        'dependencies':[], 'inputs':[{'id':'file','title':'File','type':'string','default':''}], 'modules':[], 'auto_imports':[],
        'sheets':[{'id':'main','title':'Main','cells':[{'id':'1','kind':'code','mode':'manual','source':'42\n'}]}],
        'boards':[{'id':'media','title':'Media','sheet':'main','columns':1,'components':[
            {'id':'file','kind':'file_input','title':'File','input':'file'},
            {'id':'audio','kind':'audio_input','title':'Audio','audio_id':'clip'},
            {'id':'labels','kind':'audio_annotator','title':'Labels','audio_source':'input','audio_id':'clip','annotation_id':'audio_labels','annotation_classes':[]},
            {'id':'image','kind':'image_carousel','title':'Images','image_allow_load':True,'image_allow_read':True,'image_annotator':True,'annotation_id':'labels','annotation_classes':[]}]}],
        'future':9223372036854775807}
    manifest = book / 'project.json'; manifest.write_text(json.dumps(document))
    payload = root / 'payload.bin'
    def accept(component, data, extension, operation='replace', succeeds=True):
        payload.write_bytes(data)
        result = subprocess.run([str(WORKER), '--media-input', str(book), 'media', component, extension, 'Name.'+extension, operation, str(payload)], capture_output=True)
        assert (result.returncode == 0) == succeeds, result.stderr.decode()
        if succeeds:
            parsed = json.loads(result.stdout)
            assert parsed['future'] == 9223372036854775807
            manifest.write_bytes(result.stdout)
            return parsed
    data=b'a,b\n1,2\n'; saved=accept('file', data,'csv')
    path=saved['inputs'][0]['default']; assert path == 'inputs/web_'+hashlib.sha256(data).hexdigest()+'.csv'
    assert (book/path).read_bytes() == data
    samples=b'\x00\x10'*800
    wav=b'RIFF'+struct.pack('<I',36+len(samples))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,8000,16000,2,16)+b'data'+struct.pack('<I',len(samples))+samples
    saved=accept('audio',wav,'wav'); path=saved['boards'][0]['components'][1]['audio_asset']; assert (book/path).read_bytes()==wav
    source = subprocess.run([str(WORKER),'--annotation-source',str(book),'media','labels',''],capture_output=True)
    assert source.returncode == 0, source.stderr.decode()
    decoded=json.loads(source.stdout); decoded['cell']=int(decoded['cell']); assert decoded['asset']==hashlib.sha256(wav).hexdigest() and decoded['frames']==800 and decoded['sample_rate']==8000
    assert len(base64.b64decode(decoded.pop('data')))==800*4
    audio_labels=dict(decoded,version=1,transcript='',classes=[],segments=[dict(id='s',title='',start_frame=0,end_frame=800,low_hz=100,high_hz=2000,classes=[],attributes={},transcript='')])
    accepted=accept('labels',json.dumps(audio_labels).encode(),'json','annotations');assert accepted['boards'][0]['components'][2]['audio_annotations']==audio_labels
    for edits in [{'asset':'a'*64},{'frames':799},{'sample_rate':16000},{'source':'cell','cell':1},{'segments':[dict(audio_labels['segments'][0],end_frame=801)]},{'segments':[dict(audio_labels['segments'][0],high_hz=4001)]}]:
        accept('labels',json.dumps(dict(audio_labels,**edits)).encode(),'json','annotations',succeeds=False)
    accept('labels',b'null','json','annotations')
    png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==')
    saved=accept('image',png,'png'); saved=accept('image',png,'png','append'); assert len(saved['boards'][0]['components'][3]['image_items'])==2
    labels={'version':1,'asset':hashlib.sha256(png).hexdigest(),'channel':'image','width':1,'height':1,'classes':[],'shapes':[{'id':'one','kind':'point','label':'Pixel','x':0,'y':0,'classes':[],'attributes':{}}]}
    accepted=accept('image',json.dumps(labels).encode(),'json','annotations'); assert accepted['boards'][0]['components'][3]['annotations']==labels
    for edits in [{'asset':'a'*64},{'width':2},{'channel':'other'},{'classes':[{'id':'x','title':'X','attributes':[]}]},{'shapes':[dict(labels['shapes'][0],x=0.5)]}]:
        accept('image',json.dumps(dict(labels,**edits)).encode(),'json','annotations',succeeds=False)
    accept('audio',json.dumps(labels).encode(),'json','annotations',succeeds=False)
    accept('image',b'null','json','annotations')
    saved=accept('image',b'','bin','clear'); assert not saved['boards'][0]['components'][3]['image_items']
    accept('audio',b'invalid','wav',succeeds=False)
    broken=bytearray(wav);struct.pack_into('<I',broken,4,len(wav));accept('audio',bytes(broken),'wav',succeeds=False)
    broken=bytearray(wav);struct.pack_into('<I',broken,24,1);accept('audio',bytes(broken),'wav',succeeds=False)
    floats=b'RIFF'+struct.pack('<I',40)+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,1,8000,32000,4,32)+b'data'+struct.pack('<I',4)+struct.pack('<f',float('nan'));accept('audio',floats,'wav',succeeds=False)
    accept('image',b'invalid','png',succeeds=False)
    accept('file',data,'../csv',succeeds=False)
    accept('file',data,'csv','append',succeeds=False)
    accept('unknown',data,'csv',succeeds=False)
    accept('file',b'x'*(16*1024*1024+1),'csv',succeeds=False)
    saved=accept('file',b'','bin','clear'); assert saved['inputs'][0]['default']==''
print('PASS shared file/audio/image acceptance, exact content identities/bytes, collection append/clear, Int64 preservation and invalid-media/size validation')
