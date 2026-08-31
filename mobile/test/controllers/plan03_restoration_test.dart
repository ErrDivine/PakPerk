import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/features/document_reader/document_screen.dart';
import 'package:pakperk/features/document_reader/reader_entry_context.dart';
import 'package:pakperk/features/reader_modes/reader_mode.dart';
import 'package:pakperk/core/models/semantic_span.dart';

import '../support/fakes.dart';

void main() {
  test('Library persistence index restores to Library', () {
    final restored = AppRestorationState.fromJson(const {
      'active_branch_index': 2,
    });

    expect(restored.activeBranch, AppBranch.library);
    expect(restored.activeBranchIndex, 2);
  });

  test('reader mode persists but private checkpoint anchor does not', () {
    const state = ReaderNavigationState(
      stageIndex: 1,
      depthMode: ReaderDepthMode.inspect,
      semanticDensity: SemanticDensity.detailed,
      checkpointBlockId: 'block-7',
      checkpointScrollFraction: .63,
    );

    final serialized = state.toJson();
    final restored = ReaderNavigationState.fromJson(serialized);

    expect(restored.depthMode, ReaderDepthMode.inspect);
    expect(restored.semanticDensity, SemanticDensity.detailed);
    expect(restored.checkpointBlockId, isNull);
    expect(restored.checkpointScrollFraction, isNull);
    expect(serialized, isNot(contains('checkpoint_block_id')));
    expect(serialized, isNot(contains('checkpoint_scroll_fraction')));
    expect(restored.toJson(), isNot(contains('library_state')));
  });

  test('legacy unscoped checkpoint anchors are ignored on decode', () {
    final restored = ReaderNavigationState.fromJson(const {
      'stage_index': 1,
      'depth_mode': 'read',
      'checkpoint_block_id': 'account-a-private-block',
      'checkpoint_scroll_fraction': .82,
    });

    expect(restored.stageIndex, 1);
    expect(restored.depthMode, ReaderDepthMode.read);
    expect(restored.checkpointBlockId, isNull);
    expect(restored.checkpointScrollFraction, isNull);
  });

  test('explicit connection origin remains typed after restoration', () {
    final entry = PaperRouteEntry(
      routeId: 'route-a',
      paper: samplePaper,
      entryContext: const ReaderEntryContext.connection(
        originReaderKey: 'feed:origin',
      ),
    );

    final restored = PaperRouteEntry.fromJson(entry.toJson());

    expect(restored.entryContext.source, ReaderEntrySource.connection);
    expect(
      restored.entryContext.queueMembership,
      ReaderQueueMembership.outsideToRead,
    );
    expect(restored.entryContext.originReaderKey, 'feed:origin');
  });

  test('remote checkpoint applies only to a pristine local reader', () {
    expect(
      shouldApplyRemoteReaderCheckpoint(const ReaderNavigationState()),
      isTrue,
    );
    expect(
      shouldApplyRemoteReaderCheckpoint(
        const ReaderNavigationState(introductionOffset: 12),
      ),
      isFalse,
    );
    expect(
      shouldApplyRemoteReaderCheckpoint(
        const ReaderNavigationState(depthMode: ReaderDepthMode.read),
      ),
      isFalse,
    );
    expect(
      shouldApplyRemoteReaderCheckpoint(
        const ReaderNavigationState(checkpointBlockId: 'local-block'),
      ),
      isFalse,
    );
  });
}
