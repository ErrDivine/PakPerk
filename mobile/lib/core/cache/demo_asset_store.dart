import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/paper.dart';

abstract interface class DemoContentStore {
  Future<FeedPage> loadFallbackFeed();
  Future<PaperSummary?> findFallbackPaper(String paperId);
  Future<PaperSummary?> findFallbackPaperByArxiv(String arxivBaseId);
  Future<PaperIntroduction?> loadIntroduction(String paperId);
  Future<PaperConnections?> loadConnections(String paperId);
}

class BundleDemoContentStore implements DemoContentStore {
  BundleDemoContentStore({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  FeedPage? _feed;
  Map<String, dynamic>? _introductions;
  Map<String, dynamic>? _connections;

  @override
  Future<FeedPage> loadFallbackFeed() async {
    if (_feed != null) return _feed!;
    final raw = await _bundle.loadString('assets/fallback_feed.json');
    _feed = FeedPage.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
    return _feed!;
  }

  @override
  Future<PaperSummary?> findFallbackPaper(String paperId) async {
    final feed = await loadFallbackFeed();
    for (final paper in feed.items) {
      if (paper.paperId == paperId) return paper;
    }
    return null;
  }

  @override
  Future<PaperSummary?> findFallbackPaperByArxiv(String arxivBaseId) async {
    final target = arxivBaseId.toLowerCase();
    final feed = await loadFallbackFeed();
    for (final paper in feed.items) {
      if (paper.arxivBaseId.toLowerCase() == target) return paper;
    }
    return null;
  }

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) async {
    _introductions ??= await _loadOptionalMap(
      'assets/prepared_introductions.json',
    );
    final value = _paperValue(_introductions!, paperId);
    return value == null ? null : PaperIntroduction.fromJson(value);
  }

  @override
  Future<PaperConnections?> loadConnections(String paperId) async {
    _connections ??= await _loadOptionalMap('assets/prepared_connections.json');
    final value = _paperValue(_connections!, paperId);
    return value == null ? null : PaperConnections.fromJson(value);
  }

  Future<Map<String, dynamic>> _loadOptionalMap(String asset) async {
    try {
      final raw = await _bundle.loadString(asset);
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on Object {
      // Strict staging/production flavors intentionally omit prototype
      // derived content. Treat an absent or invalid optional asset exactly as
      // unavailable content; the network capability path remains authoritative.
      return const {};
    }
  }

  Map<String, dynamic>? _paperValue(Map<String, dynamic> root, String paperId) {
    final papers = root['papers'];
    final value = papers is Map ? papers[paperId] : root[paperId];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
}
