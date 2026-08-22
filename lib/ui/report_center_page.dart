import 'package:flutter/material.dart';

import 'bill_report_page.dart';
import 'extension_menu.dart';
import 'outbound_report_page.dart';

// 报表中心：各类报表的入口列表
class ReportCenterPage extends StatelessWidget {
  const ReportCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = [
      ExtensionMenuItem(
        title: '出库报表',
        subtitle: '按日期区间导出出库材料记录',
        icon: Icons.output_outlined,
        builder: (context) => const OutboundReportPage(),
      ),
      ExtensionMenuItem(
        title: '账单报表',
        subtitle: '按日期、账本、账户筛选导出账单',
        icon: Icons.receipt_long_outlined,
        builder: (context) => const BillReportPage(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('报表中心')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) => ExtensionMenuCard(item: items[index]),
        ),
      ),
    );
  }
}
