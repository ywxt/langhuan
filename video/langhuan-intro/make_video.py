from PIL import Image, ImageDraw, ImageFont
import argparse
import asyncio
import json
import re
import shutil
import subprocess
import tempfile
from functools import lru_cache
import edge_tts
import imageio_ffmpeg
from pathlib import Path
P=Path(__file__).resolve().parent
SCREENSHOTS=P.parent.parent/'docs/screenshots'
SCENE_SCREENSHOTS={'sources':'sources', 'login':'login', 'comments':'comments',
                   'read':'reader', 'security':'source-details',
                   'agent':'developer', 'end':'sources'}
F=subprocess.check_output(['fc-match', 'Noto Sans CJK SC', '-f', '%{file}'], text=True).strip()
ff=imageio_ffmpeg.get_ffmpeg_exe(); W,H=1920,1080
scenes=[
('换个阅读器，\n登录和段评呢？','琅嬛 · 开源跨平台网文阅读器','换个阅读器，原站的登录和段评，还能不能一起用？这是琅嬛，一款开源的跨平台小说阅读器。','intro'),
('把想读的网站，\n接进同一个界面','某茄 · 某点 · 某江 · 导入信任的书源','先导入你信任的书源。某茄、某点、某江，就能在同一个界面里找书、阅读。','sources'),
('用自己的账号，\n回到熟悉的阅读界面','原站账号 · 应用内登录与验证 · 需书源支持','遇到需要账号的网站，在支持的书源里，可以用自己的原站账号登录、完成验证，再回到熟悉的阅读界面。','login'),
('读到这一段，\n看看原站怎么说','原站段评 · 章节评论 · 查看已有回复','读到想吐槽的一段，点开就能查看原站段评。章节评论、已有回复，也放进同一套界面。','comments'),
('正文怎么排，\n按你的习惯来','字体与主题 · 正文整理 · 书架进度','正文怎么排，你来定。翻页、字体、主题，还有单本书的正文整理，都能按习惯调整。读到哪儿，书架记下来。','read'),
('导入书源，\n心里更有底','先看访问范围 · 越界请求拦截 · 本地文件保护','导入前，先看清书源要访问哪些网站。越界请求会被拦下，它也不能随意读取你的本地文件。','security'),
('想写自己的书源？\n让 AI 帮着做','连接本地 AI Agent · 写脚本 · 跑测试 · 看结果','想写自己的书源，可以连接本地 AI，帮你写脚本、跑测试，再根据结果修改。','agent'),
('琅嬛 Langhuan','开源项目 · 持续开发中 · 链接见简介','琅嬛还在持续开发。项目链接放在简介里，欢迎试用，也欢迎把问题和建议带回来。','end')]

@lru_cache(maxsize=32)
def font(n):
 try:
  f=ImageFont.truetype(F,n,index=2)
 except OSError:
  f=ImageFont.truetype(F,n)
 try:
  axes=f.get_variation_axes()
  f.set_variation_by_axes([550 if n >= 70 else 400] + [axis['default'] for axis in axes[1:]])
 except OSError:
  pass
 return f
def rr(d,box,r,fill): d.rounded_rectangle(box,radius=r,fill=fill)
def draw_scene(i, output=None):
 title,sub,voice,kind=scenes[i]; im=Image.new('RGB',(W,H),'#f7f9f4'); d=ImageDraw.Draw(im)
 if kind=='intro':
  im=Image.new('RGB',(W,H),'#061f20'); d=ImageDraw.Draw(im)
  d.rectangle((0,0,W,12),fill='#9fe870')
  d.text((125,104),'LANGHUAN  /  琅嬛',font=font(28),fill='#9fe870')
  rr(d,(125,213,427,268),27,'#9fe870'); d.text((149,222),'琅嬛 · 网络小说阅读器',font=font(23),fill='#163300')
  headline=title.split('\n')
  d.text((115,302),headline[0],font=font(97),fill='#f4f8ef',stroke_width=2)
  d.text((115,455),headline[1],font=font(92),fill='#9fe870',stroke_width=2)
  d.text((127,637),'原站账号、读者评论，接进熟悉的阅读界面。',font=font(32),fill='#c1d4c7')
  icon=Image.open(P.parent.parent/'assets/branding/langhuan-app-icon.png').convert('RGB').resize((690,690),Image.Resampling.LANCZOS)
  im.paste(icon,(1130,125)); d=ImageDraw.Draw(im)
  d.text((125,1000),'书源需自行导入  ·  项目持续开发中',font=font(19),fill='#a5b9a9')
  im.save(output or P/f'scene{i}.png'); return
 d.rectangle((0,0,W,14),fill='#9fe870'); d.text((120,75),'琅嬛  /  LANGHUAN',font=font(26),fill='#163300')
 d.text((120,245),title,font=font(90),fill='#163300',spacing=20,stroke_width=0)
 d.text((125,550),sub,font=font(31),fill='#455344')
 rr(d,(120,652,375,714),31,'#9fe870'); d.text((151,663),'阅读，自在一点',font=font(24),fill='#163300')
 # Real Flutter window captures; retain their aspect ratio and UI content.
 screenshot=Image.open(SCREENSHOTS/f'{SCENE_SCREENSHOTS[kind]}.png').convert('RGB')
 screenshot.thumbnail((650,820),Image.Resampling.LANCZOS)
 x=1475-screenshot.width//2; y=104
 rr(d,(x-12,y-12,x+screenshot.width+12,y+screenshot.height+12),16,'#dde5d8')
 im.paste(screenshot,(x,y)); d=ImageDraw.Draw(im)
 caption={'comments':'原站段评 · 热门评论与回复入口',
          'security':'书源详情 · 声明的访问域名',
          'agent':'开发者工具 · Agent API 入口'}.get(kind,'Linux 桌面版 · 实际运行截图')
 d.text((x,y+screenshot.height+22),caption,font=font(21),fill='#455344')
 if kind=='end': d.text((120,765),'github.com/ywxt/langhuan',font=font(30),fill='#163300')
 d.text((120,1003),'Linux 实机截图  ·  书源需自行导入  ·  项目持续开发中',font=font(19),fill='#687266')
 im.save(output or P/f'scene{i}.png')


# Edge voices remain synthetic. Keep the voice configurable, and accept local
# narration files so a recording or another TTS service can replace them.
DEFAULT_VOICE = 'zh-CN-YunxiNeural'
DEFAULT_RATE = '+15%'
TAIL_SECONDS = 0.18


def run_ffmpeg(*args, cwd=None):
 result = subprocess.run([ff, '-hide_banner', '-loglevel', 'error', '-y', *map(str, args)],
                         cwd=cwd, capture_output=True, text=True)
 if result.returncode:
  raise RuntimeError(result.stderr)


def audio_duration(path):
 result = subprocess.run([ff, '-i', str(path)], capture_output=True, text=True)
 match = re.search(r'Duration: (\d+):(\d+):([\d.]+)', result.stderr)
 if not match:
  raise RuntimeError(f'Cannot read audio duration: {path}')
 return int(match[1]) * 3600 + int(match[2]) * 60 + float(match[3])


async def synthesize(text, output, voice, rate):
 # 嬛 is polyphonic; the product is pronounced láng huán. Only substitute in
 # spoken input. On-screen text and exported subtitles retain 琅嬛.
 spoken = text.replace('琅嬛', '琅环')
 await edge_tts.Communicate(spoken, voice, rate=rate, boundary='SentenceBoundary').save(
     str(output), str(output.with_suffix('.jsonl')))


def subtitles(audio, text, duration):
 metadata = audio.with_suffix('.jsonl')
 if metadata.exists():
  cues = []
  for line in metadata.read_text(encoding='utf-8').splitlines():
   item = json.loads(line)
   if item['type'] == 'SentenceBoundary':
    start = item['offset'] / 10_000_000
    end = min(duration, start + item['duration'] / 10_000_000)
    cues.append((start, end, item['text'].replace('琅环', '琅嬛')))
  if cues:
   # The service sometimes overlaps adjacent sentence boundaries by ~50 ms.
   return [(start, min(end, cues[i + 1][0]) if i + 1 < len(cues) else end, caption)
           for i, (start, end, caption) in enumerate(cues)]
 return [(0, duration - TAIL_SECONDS, text)]


def timecode(seconds, srt=False):
 milliseconds = round(seconds * 1000)
 hours, milliseconds = divmod(milliseconds, 3_600_000)
 minutes, milliseconds = divmod(milliseconds, 60_000)
 sec, milliseconds = divmod(milliseconds, 1000)
 if srt:
  return f'{hours:02}:{minutes:02}:{sec:02},{milliseconds:03}'
 return f'{hours}:{minutes:02}:{sec:02}.{milliseconds // 10:02}'


def write_ass(path, cues, dark):
 color = '&H00ECF4EE' if dark else '&H00263526'
 lines = [
  '[Script Info]', 'ScriptType: v4.00+', 'PlayResX: 1920', 'PlayResY: 1080',
  'WrapStyle: 0', '[V4+ Styles]',
  'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
  f'Style: Default,Noto Sans CJK SC,32,{color},{color},&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,125,125,103,1',
  '[Events]', 'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
 ]
 for start, end, text in cues:
  text = text.replace('\\', ' ').replace('{', '（').replace('}', '）').replace('\n', r'\N')
  lines.append(f'Dialogue: 0,{timecode(start)},{timecode(end)},Default,,0,0,0,,{text}')
 path.write_text('\n'.join(lines) + '\n', encoding='utf-8')


async def voice_previews():
 text = '有些书在某茄，有些在某点、某江。书不同，阅读界面也得跟着换。琅嬛想做的，就是把这些阅读入口，放到同一个阅读器里。'
 for voice, name in [('zh-CN-YunxiNeural', '云希'), ('zh-CN-YunyangNeural', '云扬')]:
  with tempfile.TemporaryDirectory(prefix='langhuan-voice-') as folder:
   raw = Path(folder) / 'raw.mp3'
   await synthesize(text, raw, voice, DEFAULT_RATE)
   output = P / f'配音试听-{name}.mp3'
   run_ffmpeg('-i', raw, '-af', 'loudnorm=I=-16:TP=-1.5:LRA=7', '-c:a', 'libmp3lame', '-b:a', '192k', output)
   print(f'Voice preview: {output}', flush=True)


async def main(args):
 if args.preview_voices:
  await voice_previews()
  return
 with tempfile.TemporaryDirectory(prefix='.render-', dir=P) as folder:
  work = Path(folder)
  (work / 'fonts').mkdir()
  shutil.copyfile(F, work / 'fonts' / 'caption.ttc')
  audio_files = []
  for i, (_, _, _, kind) in enumerate(scenes):
   if args.narration_dir:
    audio = next((args.narration_dir / f'{kind}{ext}' for ext in ['.wav', '.mp3', '.m4a']
                  if (args.narration_dir / f'{kind}{ext}').is_file()), None)
    if audio is None:
     raise FileNotFoundError(f'Missing narration file: {kind}.wav / .mp3 / .m4a')
    audio_files.append(audio.resolve())
   else:
    audio_files.append(work / f'voice{i}.mp3')
  if not args.narration_dir:
   semaphore = asyncio.Semaphore(2)
   async def render_voice(i):
    async with semaphore:
     await synthesize(scenes[i][2], audio_files[i], args.voice, args.rate)
   await asyncio.gather(*(render_voice(i) for i in range(len(scenes))))
  combined_cues, chapters = [], []
  elapsed = 0
  for i, (_, _, text, kind) in enumerate(scenes):
   duration = audio_duration(audio_files[i]) + TAIL_SECONDS
   cues = subtitles(audio_files[i], text, duration)
   write_ass(work / f'scene{i}.ass', cues, kind == 'intro')
   draw_scene(i, work / f'scene{i}.png')
   run_ffmpeg('-loop', '1', '-framerate', '24', '-i', f'scene{i}.png',
              '-i', audio_files[i], '-t', f'{duration:.3f}',
              '-vf', f'ass=scene{i}.ass:fontsdir=fonts,format=yuv420p',
              '-af', 'loudnorm=I=-16:TP=-1.5:LRA=7,apad',
              '-ar', '48000',
              '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22',
              '-c:a', 'aac', '-b:a', '192k', f'part{i}.mp4', cwd=work)
   chapters.append((elapsed, scenes[i][0].replace('\n', '')))
   combined_cues.extend((elapsed + start, elapsed + end, caption) for start, end, caption in cues)
   # Each MP4 ends on a 24 fps frame boundary, including its quiet tail.
   elapsed += audio_duration(work / f'part{i}.mp4')
   print(f'{i + 1}/{len(scenes)} {kind}: {duration:.1f}s', flush=True)
  (work / 'concat.txt').write_text(''.join(f"file 'part{i}.mp4'\n" for i in range(len(scenes))), encoding='utf-8')
  output = P / '琅嬛-中文介绍.mp4'
  run_ffmpeg('-f', 'concat', '-safe', '0', '-i', 'concat.txt', '-c', 'copy', '-movflags', '+faststart', output, cwd=work)
  srt = ''.join(f'{i}\n{timecode(start, True)} --> {timecode(end, True)}\n{text}\n\n'
                for i, (start, end, text) in enumerate(combined_cues, 1))
  (P / '琅嬛-中文介绍.srt').write_text(srt, encoding='utf-8')
  chapter_groups = [(0, '书源与原站账号'), (3, '原站评论与阅读设置'),
                    (5, '书源访问范围与 AI 辅助维护')]
  timeline = '\n'.join(f'{int(chapters[i][0]) // 60:02}:{int(chapters[i][0]) % 60:02} {title}'
                       for i, title in chapter_groups)
  (P / '章节时间轴.txt').write_text(timeline + '\n', encoding='utf-8')
  print(f'Done: {output} ({elapsed:.1f}s)', flush=True)


if __name__ == '__main__':
 parser = argparse.ArgumentParser(description='Render the Chinese Langhuan introduction video.')
 parser.add_argument('--voice', default=DEFAULT_VOICE)
 parser.add_argument('--rate', default=DEFAULT_RATE, help='For negative values, use --rate=-2%%.')
 parser.add_argument('--preview-voices', action='store_true', help='Export Yunxi and Yunyang audition clips only.')
 parser.add_argument('--narration-dir', type=Path, help='Use local recordings named intro.wav, sources.wav, etc. Optional matching .jsonl timing metadata.')
 asyncio.run(main(parser.parse_args()))
