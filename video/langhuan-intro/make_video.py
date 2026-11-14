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
 # schematic device, clearly labelled
 rr(d,(1190,100,1650,910),54,'#163300'); rr(d,(1202,112,1638,898),44,'#ffffff')
 d.text((1240,145),'界面示意',font=font(19),fill='#849080')
 if kind in ('intro','read','clean','end'):
  d.text((1250,220),'第一章  书页之间',font=font(29),fill='#163300')
  lines=['夜色渐深，窗边亮起一盏灯。','翻开书，世界慢慢安静下来。','','每个人都有自己的阅读节奏，','也有想要珍藏的故事。','','这一页，从容地读下去。']
  for j,line in enumerate(lines): d.text((1250,300+j*63),line,font=font(24),fill='#4b5348')
  if kind=='clean': rr(d,(1242,685,1595,750),20,'#edf4e9'); d.text((1260,701),'正文整理   ·   自由组合',font=font(21),fill='#163300')
 elif kind=='comments':
  d.text((1245,220),'阅读与评论',font=font(39),fill='#163300')
  d.text((1250,300),'故事进行到精彩处……',font=font(24),fill='#455344')
  d.text((1250,360),'这一段，你怎么看？',font=font(24),fill='#455344')
  rr(d,(1240,445,1600,535),18,'#edf4e9'); d.text((1260,465),'段落评论',font=font(24),fill='#163300'); d.text((1260,503),'查看这一段的原站讨论',font=font(18),fill='#687266')
  rr(d,(1240,570,1600,660),18,'#f0f4ed'); d.text((1260,590),'章节评论与回复',font=font(24),fill='#163300'); d.text((1260,628),'查看已有评论和回复',font=font(18),fill='#687266')
  d.text((1245,745),'实际内容取决于书源支持',font=font(19),fill='#687266')
 elif kind=='agent':
  d.text((1245,220),'书源开发',font=font(40),fill='#163300')
  for j,(name,detail) in enumerate([('连接本地 Agent','启用开发者工具中的接口'),('编写书源','协助生成和修改脚本'),('运行测试','检查结果、请求和执行步骤')]):
   y=310+j*135; rr(d,(1240,y,1600,y+110),20,'#f0f4ed'); d.text((1260,y+12),name,font=font(24),fill='#163300'); d.text((1260,y+60),detail,font=font(18),fill='#687266')
  d.text((1245,755),'需自行连接本地 AI Agent',font=font(19),fill='#687266')
 elif kind in ('problem','debug','trace','finish'):
  d.text((1245,220),'开发者工具',font=font(40),fill='#163300')
  if kind=='problem':
   rr(d,(1240,310,1600,415),20,'#f0f4ed'); d.text((1260,330),'搜索没有结果？',font=font(25),fill='#163300'); d.text((1260,370),'从设置解锁开发者模式',font=font(19),fill='#687266')
   rr(d,(1240,450,1600,550),20,'#f0f4ed'); d.text((1260,480),'打开书源开发者工具',font=font(22),fill='#163300')
  elif kind=='debug':
   d.text((1250,300),'加载书源 → 选择操作',font=font(22),fill='#455344')
   for j,t in enumerate(['搜索关键词','书籍信息 / 章节','正文 / 登录状态']):
    y=365+j*105; rr(d,(1240,y,1600,y+78),18,'#f0f4ed'); d.text((1260,y+22),t,font=font(23),fill='#163300')
   rr(d,(1240,720,1600,780),30,'#9fe870'); d.text((1360,734),'运行测试',font=font(22),fill='#163300')
  elif kind=='trace':
   for j,(name,desc) in enumerate([('运行结果','输出与错误信息'),('HTTP 请求','状态、耗时与响应预览'),('执行步骤','查看每一步发生了什么')]):
    y=310+j*140; rr(d,(1240,y,1600,y+112),20,'#f0f4ed'); d.text((1260,y+12),name,font=font(24),fill='#163300'); d.text((1260,y+60),desc,font=font(19),fill='#687266')
  else:
   for j,t in enumerate(['修改脚本','重新加载并测试','通过正常流程导入']):
    y=330+j*125; rr(d,(1240,y,1600,y+90),20,'#f0f4ed'); d.text((1260,y+28),t,font=font(23),fill='#163300')
 elif kind=='login':
  d.text((1245,220),'登录与验证',font=font(40),fill='#163300')
  rr(d,(1240,305,1600,385),18,'#f0f4ed'); d.text((1260,327),'受信任书源的登录页面',font=font(22),fill='#455344')
  rr(d,(1240,430,1600,520),18,'#f0f4ed'); d.text((1260,460),'在内嵌浏览器中完成登录',font=font(21),fill='#163300')
  rr(d,(1240,545,1600,635),18,'#f0f4ed'); d.text((1260,575),'按网站要求进行人工验证',font=font(21),fill='#163300')
  rr(d,(1240,675,1600,740),30,'#9fe870'); d.text((1320,690),'返回继续阅读',font=font(23),fill='#163300')
 elif kind=='security':
  d.text((1245,220),'导入前先看看',font=font(35),fill='#163300')
  for j,(name,detail) in enumerate([('访问哪些网站','导入前查看声明的域名'),('越界请求会拦截','限制在声明的访问范围内'),('本地文件有边界','书源不能直接读取本地文件')]):
   y=310+j*140; rr(d,(1240,y,1600,y+110),20,'#f0f4ed'); d.text((1260,y+12),name,font=font(24),fill='#163300'); d.text((1260,y+58),detail,font=font(19),fill='#687266')
 elif kind=='sources':
  d.text((1245,220),'书源',font=font(43),fill='#163300')
  for j,(name,status) in enumerate([('某茄书源','示例'),('某点书源','示例'),('某江书源','示例')]):
   y=315+j*130; rr(d,(1240,y,1600,y+100),22,'#f0f4ed'); d.text((1263,y+21),name,font=font(27),fill='#163300'); d.text((1480,y+29),status,font=font(19),fill='#687266')
  d.text((1250,765),'请确认来源与访问域名',font=font(21),fill='#687266')
 elif kind=='search':
  d.text((1245,220),'搜索',font=font(43),fill='#163300'); rr(d,(1240,310,1600,377),18,'#f0f4ed'); d.text((1263,325),'输入书名或作者',font=font(23),fill='#687266')
  for j,t in enumerate(['全部书源','书源 A','书源 B']): rr(d,(1240+j*118,405,1350+j*118,450),20,'#9fe870' if j==0 else '#f0f4ed'); d.text((1250+j*118,413),t,font=font(17),fill='#163300')
  for j in range(3):
   y=490+j*105; rr(d,(1240,y,1600,y+86),17,'#f0f4ed'); rr(d,(1253,y+12,1300,y+74),7,['#9db6a0','#d0c2aa','#a9bbc2'][j]); d.text((1320,y+12),'搜索结果示例',font=font(22),fill='#163300'); d.text((1320,y+46),'书名 · 作者 · 来源',font=font(16),fill='#687266')
 else:
  d.text((1245,220),'书架',font=font(43),fill='#163300'); rr(d,(1240,300,1600,360),16,'#f0f4ed'); d.text((1260,312),'搜索书籍',font=font(22),fill='#687266')
  for j in range(3):
   x=1242+j*120; rr(d,(x,410,x+100,560),12,['#a4bca4','#c6b79c','#a6bac1'][j]); d.text((x+10,450),'故事',font=font(24),fill='#ffffff'); d.text((x,575),'书籍示例',font=font(17),fill='#163300'); d.text((x,608),'阅读中',font=font(16),fill='#687266')
 if kind=='end': d.text((120,765),'github.com/ywxt/langhuan',font=font(30),fill='#163300')
 d.text((120,1003),'画面为功能示意  ·  书源需自行导入  ·  项目持续开发中',font=font(19),fill='#687266')
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
