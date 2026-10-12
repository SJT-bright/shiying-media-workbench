import subprocess,json,tempfile,sys
from pathlib import Path
worker=Path('/Applications/拾影.app/Contents/Resources/worker/拾影Worker')
with tempfile.TemporaryDirectory(prefix='shiying-cancel-') as folder:
 root=Path(folder); original=root/'original.txt'; original.write_text('preserve this existing user file')
 p=subprocess.Popen([str(worker),'download','--link','https://v.douyin.com/TrJh2pK0v14/','--quality','480','--folder',folder],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 events=[]
 for line in p.stdout:
  event=json.loads(line); events.append(event['event'])
  if event.get('stage')=='export':
   p.terminate(); break
 rest,stderr=p.communicate(timeout=15)
 assert p.returncode==130,(p.returncode,stderr)
 assert original.read_text()=='preserve this existing user file'
 assert list(root.iterdir())==[original],list(root.iterdir())
 result={'cancelled_at':'export','exit_code':p.returncode,'staging_removed':True,'existing_file_unchanged':True}
 Path('douyin-pocket/docs/cancellation-validation.json').write_text(json.dumps(result,indent=2))
 print(result)
