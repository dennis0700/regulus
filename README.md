# regulus

原生 macOS 鸟类摄影 App：从文件夹、存储卡或相机（USB）导入照片，自动检测鸟、识别鸟种并评分，把星级和鸟种写回照片。

## 功能

- 导入：按类型和拍摄日期整理到 `照片库/{Raw,Jpeg,HEIF,Video}/yyyyMMdd/`，自动跳过已导入的照片；可选导入后删除原文件
- 分析：评分、识别鸟种，或两者一起做；识别可按拍摄地区（国家、省 / 州）筛选。AI 评出 1–3 星的照片写入星级，0 星的自动标为排除（已有人工评分或旗标的照片不改）
- 照片库：缩略图、大图预览、文件夹管理、旗标、1–5 星评分
- 写回照片：星级、旗标和鸟种直接写进照片文件（XMP），不另存数据库。支持 JPEG、HEIC 以及 CR3、ARW、NEF、ORF、RW2 等 RAW

## 安装

需要 macOS 14+ 和 Apple Silicon。

1. 从 [Releases](https://github.com/dennis0700/regulus/releases/latest) 下载 `Regulus.zip`，解压后把 Regulus 放进「应用程序」
2. App 未经 Apple 公证，首次打开若被拦截，请到「系统设置 › 隐私与安全性」点「仍要打开」
3. 在「设置 › 模型」里下载模型

App 会自动检查更新，可在「设置 › 通用」关闭。

## 许可

本项目为 AGPL-3.0。模型来自 [superpicky-coreml](https://github.com/dennis0700/superpicky-coreml)，其中 BirdTrace、TOPIQ 和 eBird 地区名录仅限非商业使用，因此 regulus 连同模型只能用于非商业用途。

评分与锐度算法移植自 [SuperPicky](https://github.com/jamesphotography/SuperPicky)（AGPL-3.0），已改写为 Swift 并有删改，出处见各源文件注释。
