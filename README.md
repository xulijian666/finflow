FinFlow 个人记账

概述
这是一个基于 Flutter 与 SQLite 的极简风格个人记账应用，支持收入与支出记录的快速录入，数据本地持久化保存，交互流程简洁流畅。

功能概览
- 收入/支出记录，金额、分类、日期、备注
- SQLite 本地持久化存储
- 极简 Material Design 风格界面
- 快速录入：底部弹层 + 数字键盘
- 支持记录编辑与删除

运行环境
- Flutter 3.x
- Android、Windows（Windows 用于调试）

快速开始
1. 安装依赖
   flutter pub get
2. 运行应用
   flutter run -d windows
3. 打包apk
   flutter build apk --release -v

数据结构
交易记录表（records）
- id：主键
- type：类型（income / expense）
- amount：金额
- category：分类
- date：日期（ISO 字符串）
- note：备注

项目结构
- lib/data/transaction_record.dart：数据模型
- lib/data/record_database.dart：SQLite 数据库与增删改查
- lib/ui/home_page.dart：主界面与记录列表
- lib/ui/record_form_sheet.dart：快速记账面板与数字键盘
- lib/main.dart：应用入口与主题

交互说明
- 点击“记一笔”打开快速录入面板
- 输入金额、选择分类与日期、填写备注后保存
- 记录可点击编辑，右滑删除

