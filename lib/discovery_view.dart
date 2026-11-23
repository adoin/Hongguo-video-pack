import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'data/discovery_client.dart';
import 'discovery_controller.dart';
import 'domain/discovery.dart';

const _accent = Color(0xFFC20032),
    _ink = Color(0xFF24242D),
    _muted = Color(0xFF858590);

class DiscoveryView extends StatefulWidget {
  const DiscoveryView({
    super.key,
    required this.controller,
    required this.onPick,
    this.onPlay,
    this.selectionDisabled = false,
  });
  final DiscoveryController controller;
  final ValueChanged<DramaSummary> onPick;
  final ValueChanged<DramaSummary>? onPlay;
  final bool selectionDisabled;
  @override
  State<DiscoveryView> createState() => _DiscoveryViewState();
}

class _DiscoveryViewState extends State<DiscoveryView> {
  final search = TextEditingController();
  DiscoveryController get c => widget.controller;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'DISCOVER YOUR NEXT STORY',
          style: TextStyle(
            color: _accent,
            fontSize: 10,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '今天，想看什么故事？',
          style: TextStyle(
            color: _ink,
            fontSize: 27,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        const Text('找到喜欢的剧集，加入工作台制作完整合集。', style: TextStyle(color: _muted)),
        const SizedBox(height: 24),
        TextField(
          controller: search,
          textInputAction: TextInputAction.search,
          maxLength: 80,
          decoration: InputDecoration(
            hintText: '搜索剧名',
            counterText: '',
            fillColor: Colors.white,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.arrow_forward_rounded),
              onPressed: () =>
                  c.show(DiscoveryMode.search, keyword: search.text),
            ),
          ),
          onSubmitted: (value) => c.show(DiscoveryMode.search, keyword: value),
        ),
        const SizedBox(height: 20),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              if (c.client.theaterSupported)
                _mode(
                  DiscoveryMode.theater,
                  '剧场',
                  Icons.video_library_outlined,
                ),
              _mode(
                DiscoveryMode.ranking,
                '榜单',
                Icons.local_fire_department_outlined,
              ),
              _mode(DiscoveryMode.comic, '漫剧', Icons.auto_stories_outlined),
              _mode(DiscoveryMode.random, '随机推荐', Icons.shuffle_rounded),
              if (c.mode == DiscoveryMode.search)
                _mode(DiscoveryMode.search, '搜索结果', Icons.search),
              if (c.mode == DiscoveryMode.related)
                _mode(DiscoveryMode.related, '关联作品', Icons.link),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (c.mode == DiscoveryMode.ranking)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final b in DiscoveryClient.boards.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(b.value),
                      labelStyle: TextStyle(
                        fontSize: MediaQuery.sizeOf(context).width < 600
                            ? 12
                            : 14,
                      ),
                      labelPadding: const EdgeInsets.symmetric(horizontal: 5),
                      visualDensity: VisualDensity.compact,
                      selected: c.board == b.key,
                      side: BorderSide.none,
                      showCheckmark: false,
                      onSelected: (_) {
                        c.board = b.key;
                        c.show(DiscoveryMode.ranking);
                      },
                    ),
                  ),
              ],
            ),
          ),
        if (c.mode == DiscoveryMode.random)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final g in DiscoveryClient.categories.entries)
                ChoiceChip(
                  label: Text(g.value),
                  selected: c.category == g.key,
                  side: BorderSide.none,
                  showCheckmark: false,
                  onSelected: (_) {
                    c.category = g.key;
                    c.show(DiscoveryMode.random);
                  },
                ),
            ],
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                _description(),
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: c.mode == DiscoveryMode.random ? '换一批' : '刷新',
              onPressed: c.loading ? null : () => c.refresh(),
              icon: Icon(
                c.mode == DiscoveryMode.random ? Icons.shuffle : Icons.refresh,
              ),
            ),
          ],
        ),
        if (widget.selectionDisabled)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '拼接任务进行中，可继续播放或浏览；结束后可切换拼接剧集。',
              style: TextStyle(color: _accent),
            ),
          ),
        if (c.error != null)
          Container(
            padding: const EdgeInsets.all(18),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                Expanded(child: Text(c.error!)),
                TextButton(
                  onPressed: () => c.refresh(),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        if (c.loading)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 3),
                if (c.expandedSearch &&
                    {
                      DiscoveryMode.search,
                      DiscoveryMode.related,
                    }.contains(c.mode)) ...[
                  const SizedBox(height: 10),
                  Text(
                    '正在补充检索分类片库，已读取 ${c.indexedCount} 部。',
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        if (!c.loading && c.items.isEmpty && c.error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Center(
              child: Column(
                children: [
                  const Icon(Icons.travel_explore, color: _muted, size: 42),
                  const SizedBox(height: 16),
                  Text(
                    c.mode == DiscoveryMode.related
                        ? '暂未找到同名关联作品'
                        : c.mode == DiscoveryMode.random
                        ? '这一页已看过，点击换一批继续发现'
                        : '没有找到剧集，换个关键词试试',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        LayoutBuilder(
          builder: (context, box) {
            final columns = box.maxWidth < 540
                ? 2
                : box.maxWidth < 800
                ? 3
                : box.maxWidth < 1100
                ? 4
                : 5;
            final width = (box.maxWidth - (columns - 1) * 16) / columns;
            if (c.mode == DiscoveryMode.theater) {
              return MasonryGridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: columns,
                crossAxisSpacing: 16,
                mainAxisSpacing: 20,
                itemCount: c.items.length,
                itemBuilder: (context, i) =>
                    _tile(c.items[i], width, theater: true),
              );
            }
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: c.items.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 16,
                mainAxisSpacing: 20,
                mainAxisExtent: width * 1.22 + 136,
              ),
              itemBuilder: (context, i) => _tile(c.items[i], width),
            );
          },
        ),
        if (!c.loading &&
            c.result?.hasMore == true &&
            {
              DiscoveryMode.theater,
              DiscoveryMode.ranking,
              DiscoveryMode.comic,
            }.contains(c.mode))
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: FilledButton.tonal(
                onPressed: () => c.refresh(more: true),
                child: const Text('加载更多'),
              ),
            ),
          ),
        if (c.result != null &&
            {DiscoveryMode.search, DiscoveryMode.related}.contains(c.mode)) ...[
          const SizedBox(height: 20),
          if (c.result!.pages > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: c.loading || c.result!.page <= 1
                      ? null
                      : () => c.refresh(searchPage: c.result!.page - 1),
                  child: const Text('上一页'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    c.result!.totalPagesKnown
                        ? '${c.result!.page} / ${c.result!.pages}'
                        : '第 ${c.result!.page} 页',
                  ),
                ),
                TextButton(
                  onPressed: c.loading || !c.result!.hasMore
                      ? null
                      : () => c.refresh(searchPage: c.result!.page + 1),
                  child: const Text('下一页'),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              c.result!.scope,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ),
          if (c.result!.canExpand && !c.expandedSearch) ...[
            const SizedBox(height: 12),
            Center(
              child: FilledButton.tonalIcon(
                onPressed: c.loading ? null : c.expandSearch,
                icon: const Icon(Icons.manage_search),
                label: const Text('补充检索分类片库（较慢）'),
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                '仅在点击后扫描片库；补充结果支持分页。',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ),
          ],
        ],
        const SizedBox(height: 24),
      ],
    ),
  );

  String _description() {
    switch (c.mode) {
      case DiscoveryMode.theater:
        return '${c.items.length} 部作品';
      case DiscoveryMode.ranking:
        return c.result?.updated.isNotEmpty == true
            ? c.result!.updated
            : '红果官方热播榜 · 按来源排名';
      case DiscoveryMode.comic:
        return '漫剧剧库 · 已加载 ${c.items.length} 部';
      case DiscoveryMode.random:
        return '从所选分类随机抽取 · 换一批探索更多';
      case DiscoveryMode.search:
        if (c.result?.totalPagesKnown == false) {
          return '“${c.query}” · 当前页 ${c.items.length} 部 · 已读取 ${c.result!.total} 部';
        }
        return c.expandedSearch
            ? '“${c.query}” · 片库补充 ${c.result?.total ?? 0} 部 · 每页 20 部'
            : '“${c.query}” · 网页返回 ${c.items.length} 部'
                  '${(c.result?.sourceTotal ?? 0) > c.items.length ? ' / 来源报告 ${c.result!.sourceTotal} 条' : ''}';
      case DiscoveryMode.related:
        return '“${c.query}”同名系列检索 · 非官方关联关系';
    }
  }

  Widget _mode(DiscoveryMode mode, String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: TextButton.icon(
      onPressed: () => c.show(mode),
      icon: Icon(icon, size: 19),
      label: Text(title),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
        foregroundColor: c.mode == mode ? Colors.white : _ink,
        backgroundColor: c.mode == mode ? _ink : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );

  Widget _tile(DramaSummary drama, double width, {bool theater = false}) =>
      Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () =>
              widget.onPlay == null ? _details(drama) : widget.onPlay!(drama),
          onLongPress: () => _details(drama),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height:
                    width *
                    (theater ? (drama.vertical == false ? 1.18 : 1.42) : 1.22),
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE9E5E9),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x10000000),
                            blurRadius: 14,
                            offset: Offset(0, 5),
                          ),
                        ],
                      ),
                      child: drama.cover.isEmpty
                          ? _placeholder()
                          : Image.network(
                              drama.cover,
                              fit: BoxFit.cover,
                              cacheWidth: 360,
                              errorBuilder: (_, _, _) => _placeholder(),
                            ),
                    ),
                    if (drama.rank > 0)
                      Positioned(
                        left: 9,
                        top: 9,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: drama.rank <= 3 ? _accent : _ink,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${drama.rank}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    if (drama.episodes > 0)
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${drama.episodes} 集',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                drama.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _ink,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                drama.metric.isNotEmpty
                    ? drama.metric
                    : drama.tags.take(3).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
              if (theater && drama.intro.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  drama.intro,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => widget.onPlay == null
                          ? _details(drama)
                          : widget.onPlay!(drama),
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      label: const Text('播放'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelMedium?.copyWith(fontSize: 12),
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: widget.selectionDisabled
                          ? null
                          : () => widget.onPick(drama),
                      icon: const Icon(Icons.merge_rounded, size: 14),
                      label: const Text('拼接'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelMedium?.copyWith(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _placeholder() =>
      const Center(child: Icon(Icons.movie_outlined, size: 36, color: _muted));

  Future<void> _details(DramaSummary drama) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              drama.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Text(
              [
                if (drama.episodes > 0) '${drama.episodes} 集',
                ...drama.tags,
              ].join(' · '),
              style: const TextStyle(color: _muted),
            ),
            const SizedBox(height: 18),
            if (drama.metric.isNotEmpty) ...[
              Text(
                drama.metric,
                style: const TextStyle(
                  color: _accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(drama.intro.isEmpty ? '暂无剧情介绍' : drama.intro),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.selectionDisabled
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        widget.onPick(drama);
                      },
                icon: const Icon(Icons.add_rounded),
                label: Text(widget.selectionDisabled ? '当前任务完成后可切换' : '加入工作台'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
