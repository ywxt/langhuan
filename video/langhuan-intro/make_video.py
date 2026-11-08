from PIL import Image, ImageDraw, ImageFont
import asyncio, edge_tts, imageio_ffmpeg, subprocess, re, os, math
from pathlib import Path
P=Path(__file__).resolve().parent
F='/nix/store/9swv95wd3z6358f5rcf6fpmal1nx06q5-noto-fonts-cjk-sans-2.004/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc'
ff=imageio_ffmpeg.get_ffmpeg_exe(); W,H=1920,1080
scenes=[
('追书，别让切换打断','一个阅读空间 · 多个书源','追书追着追着，手机里装满了阅读软件？换一个平台，就要重新适应一套界面？','intro'),
('书在不同网站，\n阅读不用四处奔波','导入信任的书源 · 汇聚不同网站','试试琅嬛。比如某茄、某点，导入对应的书源，就能把不同网站的阅读入口放在一起。','sources'),
('想看的书，\n一次搜索，多处寻找','多书源聚合搜索 · 结果独立保留','书名输入一次，多个已启用书源一起找。即使某个来源暂时失联，其他结果依然在。','search'),
('遇到登录？\n故事不必停在这里','内嵌浏览器登录 · 人工验证 · 使用会话','碰到需要登录或人工验证的网站？支持的书源，可以在应用内完成验证，再使用登录会话。','login'),
('喜欢的故事，\n收进自己的书架','阅读进度 · 更新检查 · 章节缓存','找到想看的书，就放上书架。进度记下来，更新查得到，缓存章节，下次继续沉浸。','shelf'),
('翻页还是下滑？\n你说了算','横向翻页 · 纵向阅读 · 自定义主题','不必再迁就每个网站的界面。翻页、下滑、字体、间距和主题，都按你的阅读节奏来。','read'),
('读到精彩处，\n一起聊聊','章节评论 · 段落评论 · 取决于书源支持','看到精彩的地方，不必一个人激动。支持评论的书源，可以查看章节或段落评论。','comments'),
('看不顺眼的正文，\n也能重新整理','中文转换 · 正则替换 · 单书规则','繁简转换、替换文字、删除段落，规则自由组合；一本书，也能有自己的整理方式。','clean'),
('想做自己的书源？\n让 AI Agent 来帮忙','连接本地 Agent · 编写脚本 · 测试结果','想为喜欢的网站编写书源？连接本地 AI Agent，协助编写脚本、运行测试，快速迭代。','agent'),
('琅嬛 Langhuan','一个阅读空间 · 你来选择书源与阅读方式','让找书少一点折腾，让阅读多一点自由。琅嬛仍在开发中，欢迎来看看。','end')]

def font(n): return ImageFont.truetype(F,n,index=2)
def rr(d,box,r,fill): d.rounded_rectangle(box,radius=r,fill=fill)
def draw_scene(i):
 title,sub,voice,kind=scenes[i]; im=Image.new('RGB',(W,H),'#f7f9f4'); d=ImageDraw.Draw(im)
 if kind=='intro':
  im=Image.new('RGB',(W,H),'#061f20'); d=ImageDraw.Draw(im)
  d.rectangle((0,0,W,12),fill='#9fe870')
  d.text((125,104),'LANGHUAN  /  琅嬛',font=font(28),fill='#9fe870')
  rr(d,(125,213,427,268),27,'#9fe870'); d.text((149,222),'琅嬛 · 网络小说阅读器',font=font(23),fill='#163300')
  d.text((115,302),'追书，',font=font(107),fill='#f4f8ef',stroke_width=2)
  d.text((115,455),'非得来回切换？',font=font(92),fill='#9fe870',stroke_width=2)
  d.text((127,637),'不同网站，一个阅读空间。',font=font(32),fill='#c1d4c7')
  icon=Image.open(P.parent.parent/'assets/branding/langhuan-app-icon.png').convert('RGB').resize((690,690),Image.Resampling.LANCZOS)
  im.paste(icon,(1130,125)); d=ImageDraw.Draw(im)
  d.text((125,930),voice,font=font(27),fill='#eef4ec')
  d.text((125,1000),'书源需自行导入  ·  项目持续开发中',font=font(19),fill='#a5b9a9')
  im.save(P/f'scene{i}.png'); return
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
  rr(d,(1240,445,1600,535),18,'#edf4e9'); d.text((1260,465),'段落评论',font=font(24),fill='#163300'); d.text((1260,503),'读到这里，忍不住想聊聊',font=font(18),fill='#687266')
  rr(d,(1240,570,1600,660),18,'#f0f4ed'); d.text((1260,590),'章节评论',font=font(24),fill='#163300'); d.text((1260,628),'和其他读者分享感受',font=font(18),fill='#687266')
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
  d.text((1245,220),'书源权限',font=font(40),fill='#163300')
  for j,(name,detail) in enumerate([('来源信息','查看发布者与书源 ID'),('访问域名','请求需要匹配声明的域名'),('脚本沙箱','资源使用受到限制')]):
   y=310+j*140; rr(d,(1240,y,1600,y+110),20,'#f0f4ed'); d.text((1260,y+12),name,font=font(24),fill='#163300'); d.text((1260,y+58),detail,font=font(19),fill='#687266')
 elif kind=='sources':
  d.text((1245,220),'书源',font=font(43),fill='#163300')
  for j,(name,status) in enumerate([('某茄书源','示例'),('某点书源','示例'),('其他书源','示例')]):
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
 d.text((120,940),voice,font=font(27),fill='#263526')
 d.text((120,1003),'画面为功能示意  ·  书源需自行导入  ·  项目持续开发中',font=font(19),fill='#687266')
 im.save(P/f'scene{i}.png')
async def voice(i): await edge_tts.Communicate(scenes[i][2], 'zh-CN-XiaoxiaoNeural', rate='+5%').save(str(P/f'voice{i}.mp3'))
async def main():
 await asyncio.gather(*(voice(i) for i in range(len(scenes))))
 for i in range(len(scenes)):
  draw_scene(i)
  p=subprocess.run([ff,'-i',str(P/f'voice{i}.mp3')],capture_output=True,text=True)
  m=re.search(r'Duration: (\d+):(\d+):([\d.]+)',p.stderr); duration=max(6.5,int(m[1])*3600+int(m[2])*60+float(m[3])+1.2)
  subprocess.run([ff,'-y','-loop','1','-framerate','24','-i',str(P/f'scene{i}.png'),'-i',str(P/f'voice{i}.mp3'),'-t',str(duration),'-vf',"scale=1920:1080,format=yuv420p",'-af','apad','-c:v','libx264','-preset','veryfast','-crf','22','-c:a','aac','-b:a','128k','-movflags','+faststart',str(P/f'part{i}.mp4')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
  print('scene',i,'seconds',round(duration,1),flush=True)
 (P/'concat.txt').write_text(''.join(f"file 'part{i}.mp4'\n" for i in range(len(scenes))))
 subprocess.run([ff,'-y','-f','concat','-safe','0','-i',str(P/'concat.txt'),'-c','copy','-movflags','+faststart',str(P/'琅嬛-中文介绍.mp4')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
 for p in list(P.glob('scene*.png'))+list(P.glob('voice*.mp3'))+list(P.glob('part*.mp4'))+[P/'concat.txt']: p.unlink()
 print('done',flush=True)
asyncio.run(main())
