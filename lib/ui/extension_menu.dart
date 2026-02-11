import 'package:flutter/material.dart';

import 'savings_goals.dart';
import 'category_overview.dart';

// 扩展功能入口页
class ExtensionMenuPage extends StatelessWidget {
  const ExtensionMenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 扩展入口清单
    final items = [
      ExtensionMenuItem(
        title: '储蓄目标',
        subtitle: '设置目标与累计',
        icon: Icons.savings_outlined,
        builder: (context) => const SavingsGoalPage(),
      ),
      ExtensionMenuItem(
        title: '分类速览',
        subtitle: '查看分类汇总',
        icon: Icons.pie_chart_outline,
        builder: (context) => const CategoryOverviewPage(),
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
