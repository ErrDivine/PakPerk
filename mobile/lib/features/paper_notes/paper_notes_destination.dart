import '../../l10n/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/library_providers.dart';
import '../../core/models/paper.dart';
import 'paper_notes_screen.dart';
import 'paper_notes_store.dart';

/// Capture the owner when the route opens; never expose another account's notes.
class PaperNotesDestination extends ConsumerWidget {
  const PaperNotesDestination({required this.accountId, this.paper, super.key});
  final String? accountId;
  final PaperSummary? paper;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(libraryDisplayScopeProvider)?.accountId != accountId) {
      return Scaffold(
        appBar: AppBar(title: const UiText('My notes')),
        body: const Center(
          child: UiText('Account changed. Reopen your notes from Library.'),
        ),
      );
    }
    final store = SharedPreferencesPaperNotesStore(
      accountId: accountId,
      paper: paper,
    );
    return paper == null
        ? _AllPaperNotes(store: store, accountId: accountId!)
        : PaperNotesScreen(paper: paper!, store: store);
  }
}

class _AllPaperNotes extends StatefulWidget {
  const _AllPaperNotes({required this.store, required this.accountId});
  final SharedPreferencesPaperNotesStore store;
  final String accountId;
  @override
  State<_AllPaperNotes> createState() => _AllPaperNotesState();
}

class _AllPaperNotesState extends State<_AllPaperNotes> {
  late Future<List<PaperNotebook>> _notes;
  @override
  void initState() {
    super.initState();
    _notes = widget.store.list();
  }

  Future<void> _open(PaperNotebook notebook) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PaperNotesDestination(
          accountId: widget.accountId,
          paper: notebook.paper,
        ),
      ),
    );
    if (mounted) setState(() => _notes = widget.store.list());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const UiText('My notes')),
    body: FutureBuilder<List<PaperNotebook>>(
      future: _notes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() => _notes = widget.store.list()),
              child: const UiText('Could not load notes · Retry'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final notes = snapshot.data!;
        if (notes.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: UiText(
                'Your notebook is waiting.\nOpen a paper and tap the note tab to start.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: notes.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const UiText(
                'Your notes on this device, organized by paper.',
              );
            }
            final notebook = notes[index - 1];
            return Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: const Icon(Icons.auto_stories_outlined),
                title: Text(
                  notebook.paper.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: UiText(
                  '${notebook.notes.pages.length} pages · ${notebook.paper.arxivBaseId}\n${notebook.notes.pages.firstWhere((page) => page.trim().isNotEmpty)}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(notebook),
              ),
            );
          },
        );
      },
    ),
  );
}
