# 白霜拼音词库

来源：[gaboolic/rime-frost，2026-11-21，0ba3f340](https://github.com/gaboolic/rime-frost/tree/0ba3f340b9a638cef41bfb377b2d376f73e3711d)，许可见 `../../Licenses/Rime-Frost-GPL-3.0.txt`。
归档内是上游原样的 `rime_frost.dict.yaml` 和它默认启用的全部 30 张词表。没有下载可选的腾讯大词库，也不执行上游脚本。

构建学习版时，将游戏表中 22 条误用空格分栏的记录还原为制表符，在明确标注的拼音音节后补上学习版原有的分号，让自己的历史选词继续使用相同的拼音编码。中文词、拼音读音、上游词频和导入次序不变。

同一提交的 [英文主词表和补充表](https://github.com/gaboolic/rime-frost/tree/0ba3f340b9a638cef41bfb377b2d376f73e3711d/en_dicts) 原样保存在本目录，保留上游来源说明。构建时取拼写和词条相同的四字母及以上纯英文词，以及学习版 `mixed-terms.txt` 中的技术词，生成单独的 `learning_en` 表，附加到中文主词典。英文用独立的内部编码，不重写中文读音，不需要安装额外方案。
