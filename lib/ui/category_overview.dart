import 'package:flutter/material.dart';

// 分类速览示例页
class CategoryOverviewPage extends StatelessWidget {
  const CategoryOverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 示例分类数据
    final items = const [
      CategoryItem(name: '餐饮', amount: 860),
      CategoryItem(name: '交通', amount: 320),
      CategoryItem(name: '居家', amount: 540),
      CategoryItem(name: '娱乐', amount: 260),
    ];
    // 计算总支出金额
    final total = items.fold<double>(0, (sum, item) => sum + item.amount);

    return Scaffold(
      appBar: AppBar(
        title: const Text('分类速览'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '本周支出',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '￥${total.toStringAsFixed(0)}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ...items.map((item) {
            return CategoryCard(item: item, total: total);
          }),
        ],
      ),
    );
  }
}

// 分类数据结构
class CategoryItem {
  final String name;
  final double amount;

  const CategoryItem({required this.name, required this.amount});
}

// 分类展示卡片
class CategoryCard extends StatelessWidget {
  final CategoryItem item;
  final double total;

  const CategoryCard({super.key, required this.item, required this.total});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 计算占比，避免除以 0
    final ratio = total == 0 ? 0.0 : (item.amount / total);
    final clampedRatio = ratio.clamp(0.0, 1.0).toDouble();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '￥${item.amount.toStringAsFixed(0)}',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: clampedRatio,
              minHeight: 8,
              borderRadius: BorderRadius.circular(6),
              color: colorScheme.primary,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
            const SizedBox(height: 6),
            Text(
              '占比 ${(clampedRatio * 100).toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
