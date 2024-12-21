# PAL

This is a fork of SDLPAL(https://github.com/sdlpal/sdlpal).
It is ported to Navy-apps.


## Usage

我们已经把SDLPAL移植到Navy中了, 在navy-apps/apps/pal/目录下运行make init, 将会从github上克隆移植后的项目. 和Flappy Bird一样, 这个移植后的项目仍然可以在Linux native上运行: 把仙剑奇侠传的数据文件(我们在课程群的公告中发布了链接)解压缩并放到`repo/data/`目录下, 在`repo/`目录下执行`make run`即可, 可以最大化窗口来进行游戏. 不过我们把配置文件`sdlpal.cfg`中的音频采样频率SampleRate改成了11025, 这是为了在Navy中可以较为流畅地运行, 如果你对音质有较高的要求, 在Linux native中体验时可以临时改回44100. 更多的信息可以参考README.

此外, 你还需要创建配置文件`sdlpal.cfg`并添加如下内容:

```ini
OPLSampleRate=11025
SampleRate=11025
WindowHeight=200
WindowWidth=320
```

更多信息可阅读repo/docs/README.md和repo/docs/sdlpal.cfg.example.
