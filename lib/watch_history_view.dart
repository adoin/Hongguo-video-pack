import 'package:flutter/material.dart';
import 'watch_history.dart';

class RecentHistory extends StatelessWidget {
  const RecentHistory({
    super.key,
    required this.history,
    required this.onResume,
    required this.onAll,
  });
  final WatchHistory history;
  final ValueChanged<WatchPoint> onResume;
  final VoidCallback onAll;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: history,
    builder: (context, _) {
      final entries = history.entries.take(3).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '继续观看',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: onAll,
                icon: const Icon(Icons.history, size: 18),
                label: const Text('全部记录'),
              ),
            ],
          ),
          if (history.error != null)
            Text(history.error!, style: const TextStyle(color: Colors.red)),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('看过的剧集和合成视频会出现在这里。'),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: i >= entries.length
                        ? const SizedBox()
                        : _RecentCard(
                            point: entries[i].current.copy(),
                            onResume: onResume,
                          ),
                  ),
                ],
              ],
            ),
          const SizedBox(height: 20),
        ],
      );
    },
  );
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.point, required this.onResume});
  final WatchPoint point;
  final ValueChanged<WatchPoint> onResume;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => onResume(point),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                height: 72,
                width: double.infinity,
                child: point.cover.isNotEmpty
                    ? Image.network(
                        point.cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              point.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            Text(
              point.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            if (point.watched)
              const Text(
                '已看过',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
          ],
        ),
      ),
    ),
  );
  Widget _placeholder() => ColoredBox(
    color: const Color(0xFFF0E9ED),
    child: Center(
      child: Icon(
        point.local ? Icons.video_file_outlined : Icons.play_circle_outline,
      ),
    ),
  );
}

class WatchHistoryScreen extends StatefulWidget {
  const WatchHistoryScreen({
    super.key,
    required this.history,
    required this.onResume,
  });
  final WatchHistory history;
  final ValueChanged<WatchPoint> onResume;
  @override
  State<WatchHistoryScreen> createState() => _WatchHistoryScreenState();
}

class _WatchHistoryScreenState extends State<WatchHistoryScreen> {
  @override
  void initState() {
    super.initState();
    widget.history.pruneMissing();
  }

  Future<void> _remove(WatchEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条观看记录？'),
        content: const Text('仅删除历史和播放点位，保留合成视频文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除记录'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.history.remove(entry.key);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('观看记录')),
    body: ListenableBuilder(
      listenable: widget.history,
      builder: (context, _) {
        final entries = widget.history.entries;
        return RefreshIndicator(
          onRefresh: widget.history.pruneMissing,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '在线记录超过 ${widget.history.limit} 条时优先清理已看过的，再清理最早观看的；有合成文件的记录另行保留。',
              ),
              if (widget.history.error != null)
                Text(
                  widget.history.error!,
                  style: const TextStyle(color: Colors.red),
                ),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('暂无观看记录')),
                ),
              for (final entry in entries)
                Card(
                  elevation: 0,
                  child: Column(
                    children: [
                      ListTile(
                        onTap: () => widget.onResume(entry.current.copy()),
                        leading: Icon(
                          entry.current.local
                              ? Icons.video_file_outlined
                              : Icons.history,
                        ),
                        title: Text(
                          entry.current.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${entry.current.label}${entry.current.watched ? ' · 已看过' : ''}\n${entry.updated.toLocal().toString().substring(0, 16)}',
                        ),
                        trailing: IconButton(
                          tooltip: '删除记录',
                          onPressed: () => _remove(entry),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                      if (entry.files.isNotEmpty)
                        ExpansionTile(
                          title: Text('合成文件（${entry.files.length}）'),
                          children: [
                            for (final file in entry.files)
                              ListTile(
                                title: Text(file.title),
                                subtitle: Text(
                                  '${file.label}${file.path.isEmpty ? ' · 关联本地文件后继续' : ''}',
                                ),
                                leading: const Icon(Icons.play_circle_outline),
                                onTap: () => widget.onResume(file.copy()),
                              ),
                            if (entry.online != null)
                              ListTile(
                                title: const Text('继续在线剧集'),
                                subtitle: Text(entry.online!.label),
                                onTap: () =>
                                    widget.onResume(entry.online!.copy()),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
