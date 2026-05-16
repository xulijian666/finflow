# xlsx 超链接备忘录

## 核心结论

excel 包（v2.1.0）不支持超链接，需要通过 **zip 解压 → 注入 XML → 重新编码** 的方式实现。

## 完整流程

```
1. excel 包创建 workbook、写入数据、设置样式
2. workbook.save() → bytes
3. _freezeHeaderRows(bytes) → 冻结首行
4. _injectHyperlinks(bytes) → 注入超链接
5. 写入文件
```

## 踩坑记录

### 1. Sheet 名必须用默认的 `Sheet1`

**错误做法：**
```dart
final workbook = excel.Excel.createExcel();
final mainSheet = workbook['自定义名称'];
workbook.setDefaultSheet('自定义名称');
workbook.tables.remove('Sheet1'); // 或 workbook.delete('Sheet1')
```

**正确做法：**
```dart
final workbook = excel.Excel.createExcel();
final mainSheet = workbook['Sheet1']; // 直接用默认名
```

**原因：** 删除默认 Sheet1 后，workbook.xml 中的 sheet 名和实际文件路径可能对不上，导致 `sheetFileMap` 查找不到主 sheet 文件，超链接注入静默失败。

### 2. workbook.xml 中 sheet 的属性顺序不固定

excel 包生成的 `<sheet>` 标签中，`name` 和 `r:id` 属性顺序可能不同：

```xml
<!-- 可能是这种顺序 -->
<sheet name="Sheet1" r:id="rId1"/>
<!-- 也可能是这种 -->
<sheet r:id="rId1" name="Sheet1"/>
```

**正则要用 `[^>]*?` 匹配中间的任意属性：**
```dart
final sheetPattern = RegExp(
  r'<sheet\s[^>]*?name="([^"]+)"[^>]*?r:id="([^"]+)"',
);
```

### 3. 超链接注入的 XML 格式

OOXML 规范中，内部超链接只需要 `location` 属性，不需要 `relationship` 文件：

```xml
<hyperlinks>
  <hyperlink ref="B2" location="'详情Sheet名'!A1"/>
</hyperlinks>
```

- `ref`：单元格位置（如 `B2` 表示第 B 列第 2 行）
- `location`：`'Sheet名'!A1` 格式，sheet 名有特殊字符时必须加单引号

### 4. XML 注入位置

`<hyperlinks>` 必须放在 `<sheetData>` 之后、`<pageMargins>` 之前：

```dart
final idx = xml.indexOf('<pageMargins');
if (idx < 0) {
  // fallback: 放在 </worksheet> 之前
  final endIdx = xml.lastIndexOf('</worksheet>');
  return '${xml.substring(0, endIdx)}$hlXml${xml.substring(endIdx)}';
}
return '${xml.substring(0, idx)}$hlXml${xml.substring(idx)}';
```

### 5. ArchiveFile 创建方式

修改后的文件要替换原文件，用 `compress = true` 保持压缩：

```dart
final newFile = ArchiveFile(name, content.length, content)
  ..compress = true;
newArchive.addFile(newFile);
```

### 6. 冻结首行注入

通过修改 sheet XML 中的 `<sheetView>` 标签注入冻结窗格：

```xml
<sheetView>
  <pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>
</sheetView>
```

注意：excel 包可能生成自闭合的 `<sheetView .../>`，需要先转为开闭标签再注入。

## 超链接跳转方向

| 方向 | ref 示例 | location 示例 |
|------|---------|--------------|
| 目录 → 详情 | `B2`（材料名称列） | `'材料详情Sheet名'!A1` |
| 详情 → 目录 | `A1`（第一行返回链接） | `'Sheet1'!A1` |

## 样式要同步设置

超链接单元格要用 `CellStyle` 设置蓝色下划线，**同时必须带上 border**，否则边框会丢失：

```dart
final linkStyle = excel.CellStyle(
  fontColorHex: '#FF0563C1',
  underline: excel.Underline.Single,
  leftBorder: border,
  rightBorder: border,
  topBorder: border,
  bottomBorder: border,
);
```

## 参考实现

课程出库导出的超链接注入逻辑（`course_outbound_import_page.dart`）：
- `_injectHyperlinks()` — zip 解压、解析 sheet 映射、注入超链接 XML
- `_injectHyperlinksIntoSheet()` — 单个 sheet 的 XML 注入
- `_freezeHeaderRows()` — 冻结首行
- `_applyHyperlinkStyles()` — 设置超链接单元格样式
