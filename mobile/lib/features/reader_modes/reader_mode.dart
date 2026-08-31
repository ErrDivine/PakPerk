enum ReaderDepthMode {
  skim('skim', 'Skim'),
  read('read', 'Read'),
  inspect('inspect', 'Inspect');

  const ReaderDepthMode(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static ReaderDepthMode fromWire(Object? value) => switch (value) {
    'read' => ReaderDepthMode.read,
    'inspect' => ReaderDepthMode.inspect,
    _ => ReaderDepthMode.skim,
  };
}
