import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../ai/deepseek_chat_service.dart';

// 财小喵聊天页面：支持多轮上下文、重置上下文与新开对话。
class AiChatPage extends StatefulWidget {
  const AiChatPage({
    super.key,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<DeepSeekChatMessage> _history = [];
  late final DeepSeekChatService _chatService;

  DeepSeekContextBundle? _contextBundle;
  bool _loadingContext = true;
  bool _sending = false;
  String? _contextError;

  @override
  void initState() {
    super.initState();
    // 页面初始化时固定绑定当前 DeepSeek 配置。
    _chatService = DeepSeekChatService(
      config: DeepSeekConfig(
        baseUrl: widget.baseUrl,
        apiKey: widget.apiKey,
        model: widget.model,
      ),
    );
    _loadContextBundle();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadContextBundle() async {
    setState(() {
      _loadingContext = true;
      _contextError = null;
    });
    try {
      final bundle = await _chatService.buildContextBundle();
      if (!mounted) {
        return;
      }
      setState(() {
        _contextBundle = bundle;
        _loadingContext = false;
      });
      if (_history.isEmpty) {
        _appendLocalAssistantMessage(
          '喵～光燕！我是财小喵，你的专属管家猫 🐱 系统里的材料、课程、项目、库存、账单我全都帮你理好了。有什么想知道的，直接问我就行，我们一起边聊边看喵～',
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingContext = false;
        _contextError = error.toString();
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending || _loadingContext || _contextBundle == null) {
      return;
    }
    final userMessage = DeepSeekChatMessage(role: 'user', content: text);
    setState(() {
      _history.add(userMessage);
      _sending = true;
      _inputController.clear();
    });
    _scrollToBottom();
    try {
      final answer = await _chatService.sendChat(
        contextBundle: _contextBundle!,
        messages: _history,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _history.add(DeepSeekChatMessage(role: 'assistant', content: answer));
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _history.add(
          DeepSeekChatMessage(role: 'assistant', content: '这次没答上来：$error'),
        );
      });
    } finally {
      if (!mounted) {
        return;
      }
      setState(() {
        _sending = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _resetConversation() async {
    // 重置时保留固定提示词和数据库快照，只清空本轮聊天记录。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('重置上下文'),
          content: const Text('将清空当前聊天记录，但仍保留固定提示词和全部业务表数据。是否继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('重置'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _history.clear();
    });
    _appendLocalAssistantMessage('上下文已经重置完成喵～光燕，我们重新开始，我依然带着全量业务数据，随时准备好帮你理账了喵～');
  }

  void _appendLocalAssistantMessage(String content) {
    setState(() {
      _history.add(DeepSeekChatMessage(role: 'assistant', content: content));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSend =
        !_sending &&
        !_loadingContext &&
        _contextBundle != null &&
        _inputController.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('财小喵'),
        actions: [
          IconButton(
            tooltip: '重置上下文',
            onPressed: _history.isEmpty ? null : _resetConversation,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          _buildComposer(canSend),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingContext) {
      // 首次进入时先准备业务上下文，避免用户看到底层技术细节。
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('财小喵正在帮你整理业务信息...'),
          ],
        ),
      );
    }
    if (_contextError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 40,
                color: Color(0xFFB5473B),
              ),
              const SizedBox(height: 12),
              Text('上下文加载失败\n$_contextError', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _loadContextBundle,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      itemCount: _history.length + (_sending ? 1 : 0),
      itemBuilder: (context, index) {
        if (_sending && index == _history.length) {
          return const _TypingBubble();
        }
        final message = _history[index];
        final isUser = message.role == 'user';
        return _MessageBubble(isUser: isUser, content: message.content);
      },
    );
  }

  Widget _buildComposer(bool canSend) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _sendMessage(),
                decoration: InputDecoration(
                  hintText: '问问财小喵，比如”什么材料最贵？”',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: canSend ? _sendMessage : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

// 单条消息气泡。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.isUser, required this.content});

  final bool isUser;
  final String content;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foregroundColor = isUser
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () async {
          await Clipboard.setData(ClipboardData(text: content));
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已复制')));
          }
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: isUser
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: MarkdownBody(
                    data: content,
                    selectable: true,
                    shrinkWrap: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                        .copyWith(
                          p: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: foregroundColor,
                            height: 1.55,
                          ),
                          strong: TextStyle(
                            color: foregroundColor,
                            fontWeight: FontWeight.w700,
                          ),
                          em: TextStyle(
                            color: foregroundColor.withValues(alpha: 0.92),
                            fontStyle: FontStyle.italic,
                          ),
                          blockquote: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: foregroundColor, height: 1.55),
                          listBullet: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: foregroundColor),
                          h1: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: foregroundColor,
                            fontWeight: FontWeight.w700,
                          ),
                          h2: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: foregroundColor,
                            fontWeight: FontWeight.w700,
                          ),
                          h3: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: foregroundColor,
                            fontWeight: FontWeight.w700,
                          ),
                          code: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: foregroundColor,
                            fontFamily: 'monospace',
                          ),
                          codeblockDecoration: BoxDecoration(
                            color: foregroundColor.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          tableBody: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: foregroundColor, height: 1.45),
                          tableHead: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: foregroundColor,
                                fontWeight: FontWeight.w700,
                              ),
                          tableBorder: TableBorder.all(
                            color: foregroundColor.withValues(alpha: 0.18),
                          ),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 大模型回复中的等待态气泡。
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('财小喵正在思考中...'),
          ],
        ),
      ),
    );
  }
}
