import 'package:flutter/material.dart';

import 'material_inventory_page.dart';
import 'material_inventory_init_page.dart';
import 'base_materials_page.dart';
import 'course_outbound_import_page.dart';
import 'project_material_relation_page.dart';

// 扩展功能入口页
class ExtensionMenuPage extends StatelessWidget {
  const ExtensionMenuPage({super.key, this.onActionSelected});

  final ValueChanged<String>? onActionSelected;

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
        title: '材料库存初始化',
        subtitle: '手动新增或批量导入初始库存',
        icon: Icons.playlist_add_check_circle_outlined,
        builder: (context) => const MaterialInventoryInitPage(),
      ),
      ExtensionMenuItem(
        title: '课程出库导出',
        subtitle: '按导入数据动态年级计算并导出',
        icon: Icons.table_chart_outlined,
        builder: (context) => const CourseOutboundImportPage(),
      ),
      ExtensionMenuItem(
        title: '项目材料关系维护',
        subtitle: '维护项目/年级/课程与基础材料关系',
        icon: Icons.account_tree_outlined,
        builder: (context) => const ProjectMaterialRelationPage(),
      ),
      const ExtensionMenuItem(
        title: '账单数据导出',
        subtitle: '筛选后导出账单',
        icon: Icons.file_download_outlined,
        action: 'bill_export',
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('扩展功能')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final item = items[index];
            return ExtensionMenuCard(
              item: item,
              onActionSelected: onActionSelected,
            );
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
  final WidgetBuilder? builder;
  final String? action;

  const ExtensionMenuItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.builder,
    this.action,
  });
}

// 扩展入口卡片
class ExtensionMenuCard extends StatelessWidget {
  final ExtensionMenuItem item;
  final ValueChanged<String>? onActionSelected;

  const ExtensionMenuCard({
    super.key,
    required this.item,
    this.onActionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (item.action != null) {
          Navigator.of(context).pop(item.action);
          onActionSelected?.call(item.action!);
          return;
        }
        if (item.builder == null) {
          return;
        }
        Navigator.of(context).push(MaterialPageRoute(builder: item.builder!));
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
