import 'package:flutter/material.dart';

// 储蓄目标示例页
class SavingsGoalPage extends StatefulWidget {
  const SavingsGoalPage({super.key});

  @override
  State<SavingsGoalPage> createState() => _SavingsGoalPageState();
}

class _SavingsGoalPageState extends State<SavingsGoalPage> {
  // 目标金额与当前进度
  final double _goalAmount = 12000;
  double _currentAmount = 3200;

  // 计算进度百分比
  double get _progress {
    if (_goalAmount <= 0) {
      return 0;
    }
    return (_currentAmount / _goalAmount).clamp(0, 1);
  }

  void _addAmount(double delta) {
    // 调整当前金额，避免超出范围
    setState(() {
      _currentAmount = (_currentAmount + delta).clamp(0, _goalAmount);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 构建储蓄目标卡片
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('储蓄目标'),
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
                    '目标金额',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '￥${_goalAmount.toStringAsFixed(0)}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: colorScheme.primary,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '当前已存',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '￥${_currentAmount.toStringAsFixed(0)}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _progress,
                    minHeight: 10,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '完成度 ${(100 * _progress).toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
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
                    '快捷调整',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      ElevatedButton(
                        onPressed: () => _addAmount(100),
                        child: const Text('存入 100'),
                      ),
                      ElevatedButton(
                        onPressed: () => _addAmount(500),
                        child: const Text('存入 500'),
                      ),
                      OutlinedButton(
                        onPressed: () => _addAmount(-200),
                        child: const Text('取出 200'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
