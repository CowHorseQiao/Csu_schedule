import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

void main() {
  /// 设置导航栏颜色
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const CSUApp());
}

class CSUApp extends StatelessWidget {
  const CSUApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CSU 课表',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'), // 强制指定为中国大陆简体中文
      ],
      home: const MainScreen(),
    );
  }
}

// ==========================================
// 1. 数据模型层 (Model)
// 拓展性：以后加背景颜色、课程群聊二维码，直接在这个类里加属性
// ==========================================
class Course {
  final String name;
  final int dayOfWeek; // 1-7
  final int startPeriod; // 开始节次 (例如 1)
  final int endPeriod;   // 结束节次 (例如 2)
  final String teacher;
  final String room;
  final String weeks;
  final Color color;     // 课程卡片颜色

  Course({
    required this.name,
    required this.dayOfWeek,
    required this.startPeriod,
    required this.endPeriod,
    required this.teacher,
    required this.room,
    required this.weeks,
    required this.color,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is Course &&
              runtimeType == other.runtimeType &&
              name == other.name &&
              dayOfWeek == other.dayOfWeek &&
              startPeriod == other.startPeriod &&
              endPeriod == other.endPeriod &&
              weeks == other.weeks; // 👈 关键修复：加入 weeks 对比

  @override
  int get hashCode =>
      name.hashCode ^ dayOfWeek.hashCode ^ startPeriod.hashCode ^ endPeriod.hashCode ^ weeks.hashCode;

  // 把实体类转成 JSON 字典
  Map<String, dynamic> toJson() => {
    'name': name,
    'dayOfWeek': dayOfWeek,
    'startPeriod': startPeriod,
    'endPeriod': endPeriod,
    'teacher': teacher,
    'room': room,
    'weeks': weeks,
    'colorValue': color.value, // Color 对象不能直接存，存它的 16 进制 int 值
  };

  // 把 JSON 字典还原成实体类
  factory Course.fromJson(Map<String, dynamic> json) => Course(
    name: json['name'],
    dayOfWeek: json['dayOfWeek'],
    startPeriod: json['startPeriod'],
    endPeriod: json['endPeriod'],
    teacher: json['teacher'],
    room: json['room'],
    weeks: json['weeks'],
    color: Color(json['colorValue']),
  );
}

// ==========================================
// 2. 网络与解析层 (Parser Engine)
// 把之前的 Python BeautifulSoup 逻辑用 Dart 的 html 库重写
// ==========================================
class ScheduleParser {
  static Future<List<Course>> fetchAndParse(String cookie) async {
    const String url = 'http://csujwc.its.csu.edu.cn/jsxsd/xskb/xskb_list.do';
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Cookie': cookie,
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        },
      );

      // 防止中文乱码
      final String htmlContent = utf8.decode(response.bodyBytes);
      final dom.Document document = html_parser.parse(htmlContent);
      final dom.Element? table = document.getElementById('kbtable');

      if (table == null) return [];

      List<Course> courses = [];
      List<Color> palette = [
        Colors.blue.shade100, Colors.red.shade100, Colors.green.shade100,
        Colors.orange.shade100, Colors.purple.shade100, Colors.teal.shade100,
      ];
      Map<String, Color> courseColorMap = {};
      int colorIndex = 0;

      final rows = table.getElementsByTagName('tr');
      for (var row in rows) {
        final th = row.getElementsByTagName('th').firstOrNull;
        if (th == null) continue;

        String timeSlotText = th.text.replaceAll(RegExp(r'\s+'), '');
        if (timeSlotText.isEmpty || timeSlotText.contains('备注')) continue;

        // 解析出这是第几节课，例如 "1-2" -> start:1, end:2
        int startPeriod = 0, endPeriod = 0;
        final match = RegExp(r'(\d+)[－-](\d+)').firstMatch(timeSlotText);
        if (match != null) {
          startPeriod = int.parse(match.group(1)!);
          endPeriod = int.parse(match.group(2)!);
        } else {
          continue; // 解析不到节次则跳过
        }

        final cells = row.getElementsByTagName('td');
        List<int> daysMap = [7, 1, 2, 3, 4, 5, 6]; // 表格列对应星期

        for (int i = 0; i < cells.length; i++) {
          if (i >= daysMap.length) break;
          int dayOfWeek = daysMap[i];
          final cell = cells[i];

          // 核心：寻找隐藏的详细块
          final contentDivs = cell.getElementsByClassName('kbcontent');
          for (var div in contentDivs) {
            // 过滤空课
            if (div.text.trim().isEmpty) continue;

            // 处理单双周交替或半期课，按 "------" 分割
            final parts = div.innerHtml.split(RegExp(r'-{5,}'));
            for (var part in parts) {
              final partDoc = html_parser.parse(part);
              final texts = partDoc.body?.text.split('\n').where((s) => s.trim().isNotEmpty).toList();
              if (texts == null || texts.isEmpty) continue;

              final rawCourseText = texts[0].trim();

              final fonts = partDoc.getElementsByTagName('font');

              String teacher = "未知";
              String weeks = "未知";
              String room = "未知";
              for (var font in fonts) {
                final title = font.attributes['title'];
                if (title == '老师') teacher = font.text.trim();
                if (title == '周次(节次)') weeks = font.text.trim();
                if (title == '教室') room = font.text.trim();
              }
              final info = CourseInfo.parseCourseText(
                rawCourseText,
                teacher,
                weeks,
                room,
              );

              if (!courseColorMap.containsKey(info.name)) {
                courseColorMap[info.name] = palette[colorIndex % palette.length];
                colorIndex++;
              }
              Color courseColor = courseColorMap[info.name]!;

              courses.add(Course(
                name: info.name,
                dayOfWeek: dayOfWeek,
                startPeriod: startPeriod,
                endPeriod: endPeriod,
                teacher: info.teacher,
                room: info.room,
                weeks: info.weeks,
                color: courseColor,
              ));
            }
          }
        }
      }
      // 👇 2. 新增核心逻辑：智能合并同名断层课程 (比如把 1-8周 和 9-16周 焊死)
      List<Course> mergedCourses = [];
      for (var c in courses) {
        // 寻找除了周次以外，其他信息完全一样的课程
        int idx = mergedCourses.indexWhere((mc) =>
        mc.name == c.name &&
            mc.dayOfWeek == c.dayOfWeek &&
            mc.startPeriod == c.startPeriod &&
            mc.endPeriod == c.endPeriod &&
            mc.teacher == c.teacher &&
            mc.room == c.room);

        if (idx != -1) {
          // 提取两者的活跃周次集合并进行合并
          Course existing = mergedCourses[idx];
          Set<int> mergedWeeks = _parseWeeksToSet(existing.weeks);
          mergedWeeks.addAll(_parseWeeksToSet(c.weeks));

          // 重新转为逗号分隔的数字字符串，例如 "1,2,3...16"
          List<int> sortedWeeks = mergedWeeks.toList()..sort();
          String newWeeks = sortedWeeks.join(',');

          mergedCourses[idx] = Course(
            name: existing.name,
            dayOfWeek: existing.dayOfWeek,
            startPeriod: existing.startPeriod,
            endPeriod: existing.endPeriod,
            teacher: existing.teacher,
            room: existing.room,
            weeks: newWeeks, // 换上合并后的新周次
            color: existing.color,
          );
        } else {
          mergedCourses.add(c);
        }
      }
      return mergedCourses; // 返回合并后的干净数据
    } catch (e) {
      print('解析报错: $e');
      return [];
    }
  }

  // 👇 3. 在 ScheduleParser 类的末尾（但在类大括号内部）新增这个静态解析工具
  static Set<int> _parseWeeksToSet(String weeksStr) {
    Set<int> weeks = {};
    if (weeksStr.isEmpty || weeksStr == '未知') return weeks;

    // 解析教务系统的原始字符串
    for (int w = 1; w <= 20; w++) {
      bool active = false;
      if (weeksStr.contains('单周') && w % 2 == 1) active = true;
      if (weeksStr.contains('双周') && w % 2 == 0) active = true;

      RegExp rangeReg = RegExp(r'(\d+)-(\d+)');
      for (var match in rangeReg.allMatches(weeksStr)) {
        int start = int.parse(match.group(1)!);
        int end = int.parse(match.group(2)!);
        if (w >= start && w <= end) active = true;
      }

      RegExp singleReg = RegExp(r'(?<![\d-])(\d+)(?![\d-])');
      for (var match in singleReg.allMatches(weeksStr)) {
        if (int.parse(match.group(1)!) == w) active = true;
      }

      if (active) weeks.add(w);
    }
    return weeks;
  }

}

class CourseInfo {
  final String name;
  final String teacher;
  final String room;
  final String weeks;

  CourseInfo({
    required this.name,
    required this.teacher,
    required this.room,
    required this.weeks,
  });

  static CourseInfo parseCourseText(
      String raw,
      String teacher,
      String weeks,
      String room,
      ) {
    String name = raw;

    // 优先用 teacher 截断
    if (teacher.isNotEmpty && raw.contains(teacher)) {
      name = raw.substring(0, raw.indexOf(teacher));
    }

    // 删除括号信息
    name = name.replaceAll(RegExp(r'\(.*?\)'), '');

    // 删除职称
    name = name.replaceAll(RegExp(r'\[.*?\]'), '');

    // 删除尾部数字
    name = name.replaceAll(RegExp(r'\d+-\d+'), '');

    name = name.trim();

    return CourseInfo(
      name: name,
      teacher: teacher,
      room: room,
      weeks: weeks,
    );
  }
}

// ==========================================
// 3. 课表主界面 (UI)
// 包含 12行8列 的网格渲染逻辑
// ==========================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  List<Course> _courses = [];
  bool _isLoading = false;

  // --- 新增状态变量 ---
  int _currentWeek = 1;
  int _selectedWeek = 1;
  String _todayDateStr = "";
  String _weekdayStr = "";

  // --- 新增页面控制器 ---
  late PageController _pageController;
  // --- 新增：用于记录当前正在交互（点击变成红色）的空档格 ---
  int? _activeAddDay;    // 正在添加课程的星期几
  int? _activeAddStart;  // 正在添加课程的起始节次
  int? _activeAddEnd;    // 正在添加课程的结束节次

  bool _showTrash = false;
  bool _hoverTrash = false;
  DateTime _termStart = DateTime(2026, 3, 2);
  // 👇 新增：全局背景颜色状态（默认保持原本的灰蓝色）
  Color _bgColor = const Color(0xFFDCE0EF);
  Color get _dynamicBorderColor => Color.lerp(_bgColor, Colors.black, 0.04) ?? Colors.transparent;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(); // 先初始化
    _recalculateWeeks();       // 初始化当前时间和周次
    _loadTermStart();  // 异步加载本地保存的真实开学日期
    _loadSchedule();   // App 刚启动时，加载本地课表
    _loadBgColor(); // 👇 新增：初始化时加载保存的背景颜色
  }

  // 👇 新增：读取本地保存的背景颜色
  Future<void> _loadBgColor() async {
    final prefs = await SharedPreferences.getInstance();
    final int? colorValue = prefs.getInt('bg_color');
    if (colorValue != null) {
      setState(() {
        _bgColor = Color(colorValue);
      });
    }
  }

  // 👇 新增：保存背景颜色到本地
  Future<void> _saveBgColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bg_color', color.value);
  }

  // 👇 新增：弹出调色板底盘
  void _showBgColorPicker() {
    // 临时变量，用于在弹窗内实时预览拖拽时的颜色
    Color tempColor = _bgColor;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('自定义主题颜色', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: tempColor,
              onColorChanged: (Color color) {
                tempColor = color;
              },
              colorPickerWidth: 300,
              pickerAreaHeightPercent: 0.7,
              enableAlpha: false,         // 课表背景不需要透明度
              displayThumbColor: true,    // 显示当前选中的颜色锚点
              paletteType: PaletteType.hsvWithHue, // 启用专业 HSV 色轮
              pickerAreaBorderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
              hexInputBar: true,          // 开启 HEX 颜色代码输入框
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('确定', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () {
                setState(() => _bgColor = tempColor); // 更新全局颜色
                _saveBgColor(tempColor);              // 存入本地持久化
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // 👇 新增：从本地读取保存的开学日期
  Future<void> _loadTermStart() async {
    final prefs = await SharedPreferences.getInstance();
    final String? dateStr = prefs.getString('term_start_date');
    if (dateStr != null) {
      setState(() {
        _termStart = DateTime.parse(dateStr);
      });
      _recalculateWeeks(); // 读取后重新计算当前周
    }
  }

  void _recalculateWeeks() {
    DateTime now = DateTime.now();
    _todayDateStr = "${now.year}/${now.month}/${now.day}";
    int daysDiff = now.difference(_termStart).inDays;

    setState(() {
      _currentWeek = (daysDiff ~/ 7) + 1;
      if (_currentWeek < 1) _currentWeek = 1;
      if (_currentWeek > 20) _currentWeek = 20;

      _selectedWeek = _currentWeek;
      const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
      _weekdayStr = weekdays[now.weekday - 1];
    });

    // 让页面跳转到真实的当前周
    if (_pageController.hasClients) {
      _pageController.jumpToPage(_currentWeek - 1);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _moveCourse(Course course, int newDay, int newStart) async {
    int span = course.endPeriod - course.startPeriod;

    Course moved = Course(
      name: course.name,
      teacher: course.teacher,
      room: course.room,
      weeks: course.weeks,
      color: course.color,
      dayOfWeek: newDay,
      startPeriod: newStart,
      endPeriod: newStart + span,
    );

    // 关键：传入 course 作为忽略对象
    if (_hasConflict(moved, ignoreCourse: course)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("该时间段已有课程")));
      return;
    }

    setState(() {
      _courses.remove(course);
      _courses.add(moved);
    });

    await _saveSchedule(_courses);
  }

  // 新增 ignoreCourse 可选参数
  bool _hasConflict(Course newCourse, {Course? ignoreCourse}) {
    for (final c in _courses) {
      if (c == ignoreCourse) continue; // 关键：跳过正在移动的课程自身

      // 必须是同一天
      if (c.dayOfWeek != newCourse.dayOfWeek) continue;

      // 判断是否存在同一周同时上课
      bool weekOverlap = false;
      for (int w = 1; w <= 20; w++) {
        if (_isActiveThisWeek(c.weeks, w) &&
            _isActiveThisWeek(newCourse.weeks, w)) {
          weekOverlap = true;
          break;
        }
      }

      if (!weekOverlap) continue;

      // 判断节次是否重叠
      bool periodOverlap =
      !(newCourse.endPeriod < c.startPeriod ||
          newCourse.startPeriod > c.endPeriod);

      if (periodOverlap) {
        return true;
      }
    }
    return false;
  }

  // 判断某门课在指定的周次是否需要上
  bool _isActiveThisWeek(String weeksStr, int targetWeek) {
    if (weeksStr.contains(',')) {
      List<int> weeks = weeksStr.split(',').map((e) {
        // 过滤掉所有非数字字符（比如 "11(周)" 变成 "11"）
        String pureNumber = e.replaceAll(RegExp(r'[^\d]'), '');
        // 使用 tryParse 防止意外的空字符导致崩溃，解析失败返回 -1
        return int.tryParse(pureNumber) ?? -1;
      }).toList();
      return weeks.contains(targetWeek);
    }

    if (weeksStr.isEmpty || weeksStr == '未知') return true; // 容错处理

    // 处理单双周
    if (weeksStr.contains('单周') && targetWeek % 2 == 0) return false;
    if (weeksStr.contains('双周') && targetWeek % 2 != 0) return false;

    // 匹配 "1-8" 这种连续区间
    RegExp rangeReg = RegExp(r'(\d+)-(\d+)');
    var rangeMatches = rangeReg.allMatches(weeksStr);
    for (var match in rangeMatches) {
      int start = int.parse(match.group(1)!);
      int end = int.parse(match.group(2)!);
      if (targetWeek >= start && targetWeek <= end) return true;
    }

    // 匹配 "7,11" 这种独立周次 (利用负向先行断言排除带减号的数字)
    RegExp singleReg = RegExp(r'(?<![\d-])(\d+)(?![\d-])');
    var singleMatches = singleReg.allMatches(weeksStr);
    for (var match in singleMatches) {
      if (int.parse(match.group(1)!) == targetWeek) return true;
    }

    return false;
  }

  // 从本地加载课表
  Future<void> _loadSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonString = prefs.getString('my_schedule');
    if (jsonString != null) {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      setState(() {
        _courses = jsonList.map((json) => Course.fromJson(json)).toList();
      });
    }
  }

  // 保存课表到本地
  Future<void> _saveSchedule(List<Course> courses) async {
    final prefs = await SharedPreferences.getInstance();
    final String jsonString = jsonEncode(courses.map((c) => c.toJson()).toList());
    await prefs.setString('my_schedule', jsonString);
  }

  // 时间表
  final List<Map<String, String>> _timeConfig = [
    {'period': '1', 'time': '08:00\n08:45'},
    {'period': '2', 'time': '08:55\n09:40'},
    {'period': '3', 'time': '10:00\n10:45'},
    {'period': '4', 'time': '10:55\n11:40'},
    {'period': '5', 'time': '14:00\n14:45'},
    {'period': '6', 'time': '14:55\n15:40'},
    {'period': '7', 'time': '16:00\n16:45'},
    {'period': '8', 'time': '16:55\n17:40'},
    {'period': '9', 'time': '19:00\n19:45'},
    {'period': '10', 'time': '19:55\n20:40'},
    {'period': '11', 'time': '21:00\n21:45'},
    {'period': '12', 'time': '21:55\n22:40'},
  ];

  void _importSchedule(BuildContext context) async {
    // 跳转到 WebView 登录页并等待返回 Cookie
    final cookie = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
    );

    if (cookie != null && cookie is String) {
      setState(() => _isLoading = true);
      final parsedCourses = await ScheduleParser.fetchAndParse(cookie);
      await _saveSchedule(parsedCourses); // 将抓取到的新课表覆盖保存到本地
      setState(() {
        _courses = parsedCourses;
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('课表导入成功！')));
        _pickTermStartDate();
      }
    }
  }

  // 弹出周次选择底盘
  void _showWeekSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("选择周次", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.builder(
                  itemCount: 20,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    childAspectRatio: 1.5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    int week = index + 1;
                    bool isCurrent = week == _currentWeek;
                    bool isSelected = week == _selectedWeek;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(context); // 关掉弹窗
                        _pageController.animateToPage(
                          index,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.blue : (isCurrent ? Colors.blue.shade50 : Colors.grey.shade100),
                          borderRadius: BorderRadius.circular(8),
                          border: isCurrent ? Border.all(color: Colors.blue) : null,
                        ),
                        child: Text(
                          "第$week周",
                          style: TextStyle(
                            color: isSelected ? Colors.white : (isCurrent ? Colors.blue : Colors.black87),
                            fontWeight: isSelected || isCurrent ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              // 设置开学日期的按钮
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _pickTermStartDate(); // 唤起日期选择器
                  },
                  icon: const Icon(Icons.calendar_month),
                  label: const Text("设置本学期第一周 (周一)"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade50,
                    foregroundColor: Colors.blue,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 调用系统日历选择日期
  Future<void> _pickTermStartDate() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _termStart,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: '请选择开学第一周的任意一天',
    );

    if (picked != null) {
      // 智能处理：不管用户选了这周的周几，我们自动推算出这周的周一
      int offset = picked.weekday - 1;
      DateTime monday = picked.subtract(Duration(days: offset));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('term_start_date', monday.toIso8601String());

      _loadTermStart(); // 重新加载并刷新 UI

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已自动对齐：开学日期更新为 ${monday.year}/${monday.month}/${monday.day} (周一)')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 定义背景色
    final Brightness sysIconBrightness = _bgColor.computeLuminance() > 0.5
        ? Brightness.dark
        : Brightness.light;
    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: _bgColor,               // 底部导航栏颜色跟随背景
          systemNavigationBarIconBrightness: sysIconBrightness, // 底部图标自动黑/白
          statusBarColor: Colors.transparent,               // 顶部状态栏保持透明
          statusBarIconBrightness: sysIconBrightness,       // 顶部图标自动黑/白
        ),
        child: Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _bgColor,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque, // 扩大点击区域
          onTap: _showWeekSelector,         // 触发底部弹窗
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_todayDateStr, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text(
                _selectedWeek == _currentWeek
                    ? '第$_currentWeek周    周$_weekdayStr' // 加个小箭头提示可点击
                    : '第$_selectedWeek周    当前为第$_currentWeek周',
                style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.normal),
              ),
            ],
          ),
        ),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: '背景颜色',
            onPressed: _showBgColorPicker,
          ),
          IconButton(
            icon: const Icon(Icons.download), // 下载符号
            tooltip: '一键导入',
            onPressed: () => _importSchedule(context),
          ),
        ],
      ),
        body: Stack(
          children: [

            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_activeAddDay != null) {
                  setState(() {
                    _activeAddDay = null;
                    _activeAddStart = null;
                    _activeAddEnd = null;
                  });
                }
              },
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : PageView.builder(
                controller: _pageController,
                itemCount: 20,
                onPageChanged: (index) {
                  setState(() {
                    _selectedWeek = index + 1;
                    _activeAddDay = null;
                    _activeAddStart = null;
                    _activeAddEnd = null;
                  });
                },
                itemBuilder: (context, index) {
                  int buildWeek = index + 1;
                  return Column(
                    children: [
                      _buildHeaderRow(buildWeek),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTimeColumn(),
                              ...List.generate(7, (i) => _buildDayColumn(i + 1, buildWeek)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            /// 👇 新增：底部垃圾桶
            if (_showTrash)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: DragTarget<Course>(
                    onWillAccept: (data) {
                      setState(() {
                        _hoverTrash = true;
                      });
                      return true;
                    },
                    onLeave: (data) {
                      setState(() {
                        _hoverTrash = false;
                      });
                    },
                    onAcceptWithDetails: (details) {
                      _deleteCourse(details.data);
                    },
                    builder: (context, candidate, rejected) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: _hoverTrash ? Colors.red : Colors.red.shade300,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.delete,
                          color: Colors.white,
                          size: 40,
                        ),
                      );
                    },
                  ),
                ),
              ),

          ],
        ),
      )
    );
  }

  // 构建表头 (第一行)
  Widget _buildHeaderRow(int week) {
    final days = ['一', '二', '三', '四', '五', '六', '日'];

    // 你需要在这里设置这学期第一周周一的具体日期！
    DateTime termStart = DateTime(2026, 3, 2);
    // 计算当前选中周的周一日期
    DateTime selectedWeekStart = _termStart.add(Duration(days: (week - 1) * 7));
    int month = selectedWeekStart.month;

    return Container(
      color: _bgColor,
      child: Row(
        children: [
          // 第一列：动态显示月份
          SizedBox(
              width: 40,
              child: Center(child: Text('$month\n月', style: const TextStyle(fontSize: 12)))
          ),
          // 后面七列：推算具体日期并换行
          ...List.generate(7, (index) {
            DateTime currentDate = selectedWeekStart.add(Duration(days: index));
            return Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                    child: Text(
                        '${days[index]}\n${currentDate.day}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)
                    )
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // 构建时间列 (第一列)
  Widget _buildTimeColumn() {
    return SizedBox(
      width: 40,
      child: Column(
        // 👇 修改：使用 asMap().entries 来同时获取索引和配置
        children: _timeConfig.asMap().entries.map((entry) {
          int index = entry.key;
          var cfg = entry.value;
          int period = index + 1;

          return DragTarget<Course>(
              onAcceptWithDetails: (details) {
                // 强制当作移动到了周一处理
                _moveCourse(details.data, 1, period);
              },
              builder: (context, candidate, rejected) {
                return Container(
                  height: 70,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: _dynamicBorderColor, width: 0.4),
                    ),
                  ),
                  child: Text(
                    '${cfg['period']}\n${cfg['time']}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                  ),
                );
              }
          );
        }).toList(),
      ),
    );
  }

  // 构建每一天的课表列
  Widget _buildDayColumn(int day, int week) {
    List<Widget> cells = [];
    int p = 1;

    while (p <= 12) {
      Course? currentCourse = _courses.where((c) =>
      c.dayOfWeek == day &&
          c.startPeriod == p &&
          _isActiveThisWeek(c.weeks, week)
      ).firstOrNull;

      // 1. 检查当前格子是否是用户刚刚点击变成红色的“交互格”
      bool isActiveAdd = (_activeAddDay == day && _activeAddStart == p);

      if (isActiveAdd) {
        // 如果是交互格，渲染红色带加号的方块，高度由拖拽决定
        int span = _activeAddEnd! - _activeAddStart! + 1;
        cells.add(_buildActiveAddCell(span, day));
        p += span;
      }
      else if (currentCourse != null) {
        // 2. 正常渲染已有课程
        int span = currentCourse.endPeriod - currentCourse.startPeriod + 1;
        cells.add(_buildCourseCell(currentCourse, span));
        p += span;
      }
      else {
        int period = p; // 保存当前节次

        // 3. 渲染空档格，并加入点击事件
        cells.add(
          DragTarget<Course>(
            onAcceptWithDetails: (details) {
              _moveCourse(details.data, day, period);
            },
            builder: (context, candidateData, rejectedData) {
              return GestureDetector(
                onLongPress: () {
                  if (_activeAddDay != null) {
                    setState(() {
                      _activeAddDay = null;
                      _activeAddStart = null;
                      _activeAddEnd = null;
                    });
                    return;
                  }

                  setState(() {
                    _activeAddDay = day;
                    _activeAddStart = period;
                    _activeAddEnd = period;
                  });
                },
                child: Container(
                  height: 70,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    border: Border(
                      bottom: BorderSide(color: _dynamicBorderColor, width: 0.5),
                      right: BorderSide(color: _dynamicBorderColor, width: 0.5),
                    ),
                  ),
                ),
              );
            },
          ),
        );
        p++;
      }
    }
    return Expanded(child: Column(children: cells));
  }

  // 构建红色的“添加提示”交互格子
  Widget _buildActiveAddCell(int span, int day) {
    return GestureDetector(
      // 点击红色格子主体，跳转到添加页面
      onTap: () => _navigateToAddCourse(day),
      // 核心：处理向下滑动扩充格子的手势
      onVerticalDragUpdate: (details) {
        // 每向下滑动 70 像素（一个格子的高度），增加一节课的时长
        int newSpan = (details.localPosition.dy / 70).ceil();
        if (newSpan < 1) newSpan = 1;

        int newEnd = _activeAddStart! + newSpan - 1;
        if (newEnd > 12) newEnd = 12; // 最多不能超过第12节

        if (newEnd != _activeAddEnd) {
          setState(() {
            _activeAddEnd = newEnd;
          });
        }
      },
      onVerticalDragEnd: (_) => _navigateToAddCourse(day), // 松开手指时直接跳转
      child: Container(
        height: 70.0 * span,
        padding: const EdgeInsets.all(2),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.85),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
          child: Stack(
            children: [
              // 中间的白色加号
              const Center(child: Icon(Icons.add, color: Colors.white, size: 32)),
              // 底部的“滑动提示条”
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  height: 12,
                  decoration: const BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.only(bottomLeft: Radius.circular(6), bottomRight: Radius.circular(6)),
                  ),
                  child: const Center(child: Icon(Icons.drag_handle, color: Colors.white, size: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 跳转到添加页面并处理返回值
  void _navigateToAddCourse(int day) async {
    // 跳转前记录好时间和节次
    int start = _activeAddStart!;
    int end = _activeAddEnd!;

    final newCourse = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddCourseScreen(
          dayOfWeek: day,
          startPeriod: start,
          endPeriod: end,
          currentWeek: _selectedWeek, // 默认周次
        ),
      ),
    );

    // 从添加页面回来后，清除红色格子状态
    setState(() {
      _activeAddDay = null;
      _activeAddStart = null;
      _activeAddEnd = null;

      // 如果用户真的保存了新课程，加到列表并存入本地
      if (newCourse != null && newCourse is Course) {

        if (_hasConflict(newCourse)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("该时间段已有课程")),
          );
          return;
        }

        _courses.add(newCourse);
        _saveSchedule(_courses);
      }
    });
  }

  void _deleteCourse(Course course) async {
    bool? confirm = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("删除课程"),
        content: Text("确定删除「${course.name}」吗？"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("删除", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _courses.remove(course);
      });

      await _saveSchedule(_courses);

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("课程已删除")));
      }
    }
  }

  String _formatWeeks(String weeksStr) {
    if (weeksStr.isEmpty || weeksStr == "未知") return weeksStr;

    List<int> weeks = weeksStr.split(',')
        .map((e) => int.tryParse(e) ?? 0)
        .where((e) => e > 0)
        .toList();

    weeks.sort();

    if (weeks.isEmpty) return weeksStr;

    // 判断连续区间
    bool continuous = true;
    for (int i = 1; i < weeks.length; i++) {
      if (weeks[i] != weeks[i - 1] + 1) {
        continuous = false;
        break;
      }
    }

    if (continuous && weeks.length > 2) {
      return "${weeks.first}-${weeks.last}";
    }

    // 判断单周
    if (weeks.every((w) => w % 2 == 1)) {
      return "单周";
    }

    // 判断双周
    if (weeks.every((w) => w % 2 == 0)) {
      return "双周";
    }

    return weeksStr;
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("已复制")),
    );
  }

  void _showCourseDetail(Course course) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: GestureDetector(
          onLongPress: () => _copyText(course.name),
          child: Text(course.name),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onLongPress: () => _copyText(course.teacher),
              child: Text("教师：${course.teacher}"),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              onLongPress: () => _copyText(course.room),
              child: Text("教室：${course.room}"),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              onLongPress: () => _copyText(course.weeks),
              child: Text("周次：${_formatWeeks(course.weeks)}"),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              onLongPress: () => _copyText("第${course.startPeriod}-${course.endPeriod}节"),
              child: Text("时间：第${course.startPeriod}-${course.endPeriod}节"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("关闭"),
          ),
        ],
      ),
    );
  }

  // 构建带颜色的课程卡片
  Widget _buildCourseCell(Course course, int span) {
    return LongPressDraggable<Course>(
      key: ValueKey('${course.name}_${course.dayOfWeek}_${course.startPeriod}'),
      data: course,

      onDragStarted: () {
        setState(() {
          _showTrash = true;
        });
      },

      onDragEnd: (details) {
        setState(() {
          _showTrash = false;
          _hoverTrash = false;
        });
      },

      feedback: Material(
        elevation: 6,
        color: Colors.transparent,
        child: SizedBox(
          width: (MediaQuery.of(context).size.width - 40) / 7,
          child: _courseCard(course, span, isDragging: true),
        ),
      ),

      childWhenDragging: Opacity(
        opacity: 0.2,
        child: _courseCard(course, span),
      ),

      child: GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          _showCourseDetail(course);
        },
        child: _courseCard(course, span),
      ),
    );
  }

  Widget _courseCard(
      Course course,
      int span, {
        bool isDragging = false,
      }) {
    return Container(
      height: 70.0 * span,
      padding: const EdgeInsets.all(2),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),

          /// 渐变背景
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              course.color,
              course.color.withOpacity(0.75),
            ],
          ),

          /// 阴影（拖动时更明显）
          boxShadow: [
            BoxShadow(
              color: course.color.withOpacity(isDragging ? 0.6 : 0.35),
              blurRadius: isDragging ? 12 : 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 1.5, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            /// 顶部：课程名
            Text(
              course.name,
              textAlign: TextAlign.left,
              maxLines: span * 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                letterSpacing: -0.3, // 让汉字紧凑一点，绝对能塞下3个字
                fontWeight: FontWeight.bold,
                height: 1.1,
              ),
            ),

            const Spacer(),

            /// 底部：教师+教室
            Column(
              children: [

                if (course.teacher != "未知" && course.teacher.isNotEmpty)
                  Text(
                    course.teacher,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.black54,
                    ),
                  ),

                if (course.room != "未知" && course.room.isNotEmpty)
                  Text(
                    course.room,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.black45,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 4. 教务系统登录拦截页 (WebView)
// ==========================================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) async {
            setState(() => _isLoading = false);
            // 登录成功判定
            if (url.contains("jsxsd/framework") || url.contains("xsMain.jsp")) {
              final String cookies = await _controller.runJavaScriptReturningResult('document.cookie') as String;
              final cleanCookies = cookies.replaceAll('"', '');

              if (mounted) {
                // 成功后，关闭当前页面，并把 cookie 当作返回值传给上一个页面
                Navigator.pop(context, cleanCookies);
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('http://csujwc.its.csu.edu.cn'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      appBar: AppBar(title: const Text('授权导入课表', style: TextStyle(fontSize: 16))),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

// ==========================================
// 5. 手动添加课程页面
// ==========================================
class AddCourseScreen extends StatefulWidget {
  final int dayOfWeek;
  final int startPeriod;
  final int endPeriod;
  final int currentWeek;

  const AddCourseScreen({
    super.key,
    required this.dayOfWeek,
    required this.startPeriod,
    required this.endPeriod,
    required this.currentWeek,
  });

  @override
  State<AddCourseScreen> createState() => _AddCourseScreenState();
}

class _AddCourseScreenState extends State<AddCourseScreen> {
  Set<int> _selectedWeeks = {};
  final _formKey = GlobalKey<FormState>();

  // 表单控制器
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _teacherCtrl = TextEditingController();
  final TextEditingController _roomCtrl = TextEditingController();

  // 颜色选择器数据
  final List<Color> _colorOptions = [
    Colors.blue.shade400, Colors.red.shade400, Colors.green.shade400,
    Colors.orange.shade400, Colors.purple.shade400, Colors.teal.shade400,
    Colors.pink.shade400, Colors.indigo.shade400,
  ];
  late Color _selectedColor;

  @override
  void initState() {
    super.initState();
    _selectedColor = _colorOptions[0]; // 默认选中第一个颜色
    _selectedWeeks = {widget.currentWeek};   // 默认第1周
  }

  // 拦截返回按键，弹出确认弹窗
  Future<bool> _showExitDialog() async {
    final bool? shouldPop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃编辑？'),
        content: const Text('当前填写的内容尚未保存，确定要离开吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('留下')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('离开', style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );
    return shouldPop ?? false;
  }

  void _saveCourse() {
    if (_formKey.currentState!.validate()) {
      // 组装新的 Course 对象
      Course newCourse = Course(
        name: _nameCtrl.text.trim(),
        dayOfWeek: widget.dayOfWeek,
        startPeriod: widget.startPeriod,
        endPeriod: widget.endPeriod,
        teacher: _teacherCtrl.text.trim().isEmpty ? "未知" : _teacherCtrl.text.trim(),
        room: _roomCtrl.text.trim().isEmpty ? "未知" : _roomCtrl.text.trim(),
        weeks: _selectedWeeks.join(','),
        color: _selectedColor,
      );
      // 带着新课程数据返回上一个页面
      Navigator.pop(context, newCourse);
    }
  }

  Widget _buildWeekQuickBtn(String text, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue.shade50,
        foregroundColor: Colors.blue,
      ),
      child: Text(text),
    );
  }

  @override
  Widget build(BuildContext context) {
    const daysStr = ['一', '二', '三', '四', '五', '六', '日'];

    // PopScope 用于拦截系统返回键和左上角返回箭头
    return PopScope(
      canPop: false,
      onPopInvoked: (bool didPop) async {
        if (didPop) return;
        final bool shouldPop = await _showExitDialog();
        if (shouldPop && mounted) {
          Navigator.of(context).pop(); // 用户选择离开，强制退出
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F7FA), // 浅灰色背景更像设置页
        appBar: AppBar(
          backgroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: () async {
              if (await _showExitDialog()) Navigator.pop(context);
            },
          ),
          title: const Text('添加课程', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          actions: [
            TextButton(
              onPressed: _saveCourse,
              child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blue)),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 提示当前时间段
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    '📍 将添加至：星期${daysStr[widget.dayOfWeek - 1]}  第${widget.startPeriod}-${widget.endPeriod}节',
                    style: TextStyle(color: Colors.blue.shade800, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 20),

                // 表单填写区
                _buildTextField('课程名称', _nameCtrl, isRequired: true),
                const SizedBox(height: 12),
                _buildTextField('教室地点 (选填)', _roomCtrl),
                const SizedBox(height: 12),
                _buildTextField('授课教师 (选填)', _teacherCtrl),
                const SizedBox(height: 12),



                const Text(
                  '📅 上课周次',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),

                Row(
                  children: [
                    _buildWeekQuickBtn("全部", () {
                      setState(() {
                        Set<int> allWeeks = Set.from(List.generate(20, (i) => i + 1));

                        if (_selectedWeeks.containsAll(allWeeks)) {
                          _selectedWeeks.clear();
                        } else {
                          _selectedWeeks = allWeeks;
                        }
                      });
                    }),
                    const SizedBox(width: 10),
                    _buildWeekQuickBtn("单周", () {
                      setState(() {
                        Set<int> oddWeeks = Set.from(List.generate(10, (i) => i * 2 + 1));

                        if (_selectedWeeks.containsAll(oddWeeks)) {
                          _selectedWeeks.removeAll(oddWeeks);
                        } else {
                          _selectedWeeks.addAll(oddWeeks);
                        }
                      });
                    }),
                    const SizedBox(width: 10),
                    _buildWeekQuickBtn("双周", () {
                      setState(() {
                        Set<int> evenWeeks = Set.from(List.generate(10, (i) => (i + 1) * 2));

                        if (_selectedWeeks.containsAll(evenWeeks)) {
                          _selectedWeeks.removeAll(evenWeeks);
                        } else {
                          _selectedWeeks.addAll(evenWeeks);
                        }
                      });
                    }),
                  ],
                ),

                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(20, (index) {
                    int week = index + 1;
                    bool selected = _selectedWeeks.contains(week);

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          if (selected) {
                            _selectedWeeks.remove(week);
                          } else {
                            _selectedWeeks.add(week);
                          }
                        });
                      },
                      child: Container(
                        width: 40,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected ? Colors.blue : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$week',
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  }),
                ),

                // 颜色选择区
                const Text('🏷️ 选择课程卡片颜色', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: _colorOptions.map((color) {
                    bool isSelected = _selectedColor == color;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedColor = color),
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: color,
                        child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 辅助构建输入框
  Widget _buildTextField(String label, TextEditingController controller, {bool isRequired = false}) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.next,
      enableSuggestions: true,
      autocorrect: true,
      validator: isRequired ? (value) => value!.trim().isEmpty ? '该项不能为空' : null : null,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}