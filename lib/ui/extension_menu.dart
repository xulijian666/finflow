import 'package:flutter/material.dart';

import 'material_inventory_page.dart';
import 'base_materials_page.dart';

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
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('扩展功能'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.builder(
          itemCount: items.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.1,
          ),
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
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: item.builder),
        );
      },
      child: Ink(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  item.icon,
                  color: colorScheme.onPrimaryContainer,
                  size: 26,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                item.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                item.subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
