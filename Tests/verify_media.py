import json,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
helper=root/'dist/拾影.app/Contents/Resources/worker/拾影Worker'
probe=root/'dist/拾影.app/Contents/Resources/Tools/ffprobe'
ffmpeg=root/'dist/拾影.app/Contents/Resources/Tools/ffmpeg'
checks=[]
def verify(file,width,height,duration):
 result=subprocess.run([str(probe),'-v','error','-show_entries','format=duration,size:stream=codec_type,width,height','-of','json',str(file)],capture_output=True,text=True,check=True)
 data=json.loads(result.stdout); video=next(s for s in data['streams'] if s['codec_type']=='video')
 assert (video['width'],video['height'])==(width,height),data
 assert any(s['codec_type']=='audio' for s in data['streams']),data
 assert abs(float(data['format']['duration'])-duration)<.3,data
 subprocess.run([str(ffmpeg),'-v','error','-i',str(file),'-f','null','-'],check=True)
 checks.append({'file':file.name,'width':width,'height':height,'duration':float(data['format']['duration']),'bytes':int(data['format']['size']),'audio':True,'full_decode_exit':0})
qa=root/'build/qa'
verify(qa/'landscape-480.mp4',854,480,3)
verify(qa/'portrait-720.mp4',720,1280,3)
for file in qa.glob('*最高画质*.mp4'): verify(file,3840,2160,300.01)
(root/'docs/media-validation.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
print('Verified',len(checks),'files with bundled tools and full decode')
