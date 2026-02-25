import 'package:flutter/material.dart';

import 'material_inventory_page.dart';
import 'base_materials_page.dart';
import 'reimbursement_page.dart';

// 扩展功能入口页
class ExtensionMenuPage extends StatelessWidget {
  const ExtensionMenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 扩展入口清单
    final items = [
      ExtensionMenuItem(
        title: '基础材料',
        subtitle: '维护材料数据',
        icon: Icons.inventory_2_outlined,
        builder: (context) => const BaseMaterialsPage(),
      ),
      ExtensionMenuItem(
        title: '材料库存',
        subtitle: '查询库存变动',
        icon: Icons.warehouse_outlined,
        builder: (context) => const MaterialInventoryPage(),
      ),
      ExtensionMenuItem(
        title: '报销管理',
        subtitle: '管理报销单据',
        icon: Icons.receipt_long_outlined,
        builder: (context) => const ReimbursementPage(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('扩展功能'),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final item = items[index];
            return ExtensionMenuCard(item: item);
          },
        ),
      ),
    );
  }
}

class ExtensionMenuItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;

  // 描述单个扩展功能卡片
  ExtensionMenuItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });
}

// 扩展入口卡片
class ExtensionMenuCard extends StatelessWidget {
  final ExtensionMenuItem item;

  const ExtensionMenuCard({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: item.builder),
        );
      },
      child: Ink(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  item.icon,
                  color: colorScheme.onPrimaryContainer,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      item.subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: colorScheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
