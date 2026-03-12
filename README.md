# CSU 课表 (CSU Schedule)

🚀 一款专为中南大学 (CSU) 学生打造的轻量、纯净、高颜值的 Flutter 课表应用。

## ✨ 核心特性

* **一键导入**：内置 WebView 授权登录，直连中南大学教务系统，自动抓取并解析课表。
* **智能排课**：自动识别单双周、连续周次，智能合并同名断层课程。
* **交互式编辑**：支持长按拖拽调整课程时间，下拉空白网格快速添加自定义课程，底部丝滑拖拽删除。
* **高度个性化**：内置 HSV 专业色轮，支持全局背景色自定义（支持 HEX 代码）。独创的动态悬浮算法，边框线条会根据你的背景色自动计算出完美融合的深色系。
* **离线缓存**：基于 `shared_preferences` 的本地持久化存储，无网状态下依然秒开。

## 🛠️ 技术栈

* **框架**: Flutter (Dart)
* **网络与解析**: `http`, `html` (替代 Python BeautifulSoup 的纯 Dart 解析方案)
* **本地存储**: `shared_preferences`
* **UI 增强**: `flutter_colorpicker`, `webview_flutter`

