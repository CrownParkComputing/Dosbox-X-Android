// SDL2 scancodes, the input vocabulary of this front end.
//
// This is the DOS equivalent of the VICE app's C64 8x8 key matrix, and the
// reason the bridge takes scancodes rather than characters: DOS programs read
// the keyboard at the scancode level. A character-based API cannot express a
// held arrow key, the difference between the two Alt keys, or the numeric
// keypad as distinct from the number row -- all of which real DOS games depend
// on (the keypad in particular is how a great many flight sims steer).
//
// Values are from SDL's SDL_scancode.h and must match the SDL2 that the
// native core is linked against, since dosbox_core_key_event feeds them
// straight into MAPPER_CheckEvent.
class RetroDosboxScancode {
  RetroDosboxScancode._();

  // Letters (SDL_SCANCODE_A == 4, contiguous through Z).
  static const int a = 4;
  static const int b = 5;
  static const int c = 6;
  static const int d = 7;
  static const int e = 8;
  static const int f = 9;
  static const int g = 10;
  static const int h = 11;
  static const int i = 12;
  static const int j = 13;
  static const int k = 14;
  static const int l = 15;
  static const int m = 16;
  static const int n = 17;
  static const int o = 18;
  static const int p = 19;
  static const int q = 20;
  static const int r = 21;
  static const int s = 22;
  static const int t = 23;
  static const int u = 24;
  static const int v = 25;
  static const int w = 26;
  static const int x = 27;
  static const int y = 28;
  static const int z = 29;

  // Number row. Note 0 comes AFTER 9 in SDL's ordering, not before 1.
  static const int n1 = 30;
  static const int n2 = 31;
  static const int n3 = 32;
  static const int n4 = 33;
  static const int n5 = 34;
  static const int n6 = 35;
  static const int n7 = 36;
  static const int n8 = 37;
  static const int n9 = 38;
  static const int n0 = 39;

  static const int enter = 40;
  static const int escape = 41;
  static const int backspace = 42;
  static const int tab = 43;
  static const int space = 44;

  static const int minus = 45;
  static const int equals = 46;
  static const int leftBracket = 47;
  static const int rightBracket = 48;
  static const int backslash = 49;
  static const int semicolon = 51;
  static const int apostrophe = 52;
  static const int grave = 53;
  static const int comma = 54;
  static const int period = 55;
  static const int slash = 56;
  static const int capsLock = 57;

  static const int f1 = 58;
  static const int f2 = 59;
  static const int f3 = 60;
  static const int f4 = 61;
  static const int f5 = 62;
  static const int f6 = 63;
  static const int f7 = 64;
  static const int f8 = 65;
  static const int f9 = 66;
  static const int f10 = 67;
  static const int f11 = 68;
  static const int f12 = 69;

  static const int printScreen = 70;
  static const int scrollLock = 71;
  static const int pause = 72;
  static const int insert = 73;
  static const int home = 74;
  static const int pageUp = 75;
  static const int delete = 76;
  static const int end = 77;
  static const int pageDown = 78;
  static const int right = 79;
  static const int left = 80;
  static const int down = 81;
  static const int up = 82;

  static const int numLock = 83;
  static const int kpDivide = 84;
  static const int kpMultiply = 85;
  static const int kpMinus = 86;
  static const int kpPlus = 87;
  static const int kpEnter = 88;
  static const int kp1 = 89;
  static const int kp2 = 90;
  static const int kp3 = 91;
  static const int kp4 = 92;
  static const int kp5 = 93;
  static const int kp6 = 94;
  static const int kp7 = 95;
  static const int kp8 = 96;
  static const int kp9 = 97;
  static const int kp0 = 98;
  static const int kpPeriod = 99;

  static const int lctrl = 224;
  static const int lshift = 225;
  static const int lalt = 226;
  static const int lgui = 227;
  static const int rctrl = 228;
  static const int rshift = 229;
  static const int ralt = 230;
  static const int rgui = 231;
}

/// A named key, for the on-screen keyboard and the "assign a key to this
/// button" picker.
class RetroDosboxKey {
  /// Label drawn on the key cap.
  final String label;

  /// [RetroDosboxScancode] value sent to the core.
  final int scancode;

  /// Label for the shifted face of the key, drawn small. Presentation only --
  /// shifting is the emulated BIOS's job, not ours, so we never synthesise a
  /// different scancode for it.
  final String? shiftLabel;

  const RetroDosboxKey(this.label, this.scancode, {this.shiftLabel});
}

/// Keys grouped for the on-screen key picker, mirroring the way the VICE app's
/// C64KeyCatalogue is grouped. "Common" is first and deliberately short: it is
/// the set a DOS game actually needs bound to a touch button.
class RetroDosboxKeyCatalogue {
  RetroDosboxKeyCatalogue._();

  static const List<RetroDosboxKey> common = [
    RetroDosboxKey('Enter', RetroDosboxScancode.enter),
    RetroDosboxKey('Esc', RetroDosboxScancode.escape),
    RetroDosboxKey('Space', RetroDosboxScancode.space),
    RetroDosboxKey('Ctrl', RetroDosboxScancode.lctrl),
    RetroDosboxKey('Alt', RetroDosboxScancode.lalt),
    RetroDosboxKey('Shift', RetroDosboxScancode.lshift),
    RetroDosboxKey('Tab', RetroDosboxScancode.tab),
    RetroDosboxKey('Y', RetroDosboxScancode.y),
    RetroDosboxKey('N', RetroDosboxScancode.n),
  ];

  static const List<RetroDosboxKey> arrows = [
    RetroDosboxKey('Up', RetroDosboxScancode.up),
    RetroDosboxKey('Down', RetroDosboxScancode.down),
    RetroDosboxKey('Left', RetroDosboxScancode.left),
    RetroDosboxKey('Right', RetroDosboxScancode.right),
  ];

  static const List<RetroDosboxKey> letters = [
    RetroDosboxKey('A', RetroDosboxScancode.a),
    RetroDosboxKey('B', RetroDosboxScancode.b),
    RetroDosboxKey('C', RetroDosboxScancode.c),
    RetroDosboxKey('D', RetroDosboxScancode.d),
    RetroDosboxKey('E', RetroDosboxScancode.e),
    RetroDosboxKey('F', RetroDosboxScancode.f),
    RetroDosboxKey('G', RetroDosboxScancode.g),
    RetroDosboxKey('H', RetroDosboxScancode.h),
    RetroDosboxKey('I', RetroDosboxScancode.i),
    RetroDosboxKey('J', RetroDosboxScancode.j),
    RetroDosboxKey('K', RetroDosboxScancode.k),
    RetroDosboxKey('L', RetroDosboxScancode.l),
    RetroDosboxKey('M', RetroDosboxScancode.m),
    RetroDosboxKey('N', RetroDosboxScancode.n),
    RetroDosboxKey('O', RetroDosboxScancode.o),
    RetroDosboxKey('P', RetroDosboxScancode.p),
    RetroDosboxKey('Q', RetroDosboxScancode.q),
    RetroDosboxKey('R', RetroDosboxScancode.r),
    RetroDosboxKey('S', RetroDosboxScancode.s),
    RetroDosboxKey('T', RetroDosboxScancode.t),
    RetroDosboxKey('U', RetroDosboxScancode.u),
    RetroDosboxKey('V', RetroDosboxScancode.v),
    RetroDosboxKey('W', RetroDosboxScancode.w),
    RetroDosboxKey('X', RetroDosboxScancode.x),
    RetroDosboxKey('Y', RetroDosboxScancode.y),
    RetroDosboxKey('Z', RetroDosboxScancode.z),
  ];

  static const List<RetroDosboxKey> numbers = [
    RetroDosboxKey('1', RetroDosboxScancode.n1, shiftLabel: '!'),
    RetroDosboxKey('2', RetroDosboxScancode.n2, shiftLabel: '@'),
    RetroDosboxKey('3', RetroDosboxScancode.n3, shiftLabel: '#'),
    RetroDosboxKey('4', RetroDosboxScancode.n4, shiftLabel: r'$'),
    RetroDosboxKey('5', RetroDosboxScancode.n5, shiftLabel: '%'),
    RetroDosboxKey('6', RetroDosboxScancode.n6, shiftLabel: '^'),
    RetroDosboxKey('7', RetroDosboxScancode.n7, shiftLabel: '&'),
    RetroDosboxKey('8', RetroDosboxScancode.n8, shiftLabel: '*'),
    RetroDosboxKey('9', RetroDosboxScancode.n9, shiftLabel: '('),
    RetroDosboxKey('0', RetroDosboxScancode.n0, shiftLabel: ')'),
  ];

  static const List<RetroDosboxKey> function = [
    RetroDosboxKey('F1', RetroDosboxScancode.f1),
    RetroDosboxKey('F2', RetroDosboxScancode.f2),
    RetroDosboxKey('F3', RetroDosboxScancode.f3),
    RetroDosboxKey('F4', RetroDosboxScancode.f4),
    RetroDosboxKey('F5', RetroDosboxScancode.f5),
    RetroDosboxKey('F6', RetroDosboxScancode.f6),
    RetroDosboxKey('F7', RetroDosboxScancode.f7),
    RetroDosboxKey('F8', RetroDosboxScancode.f8),
    RetroDosboxKey('F9', RetroDosboxScancode.f9),
    RetroDosboxKey('F10', RetroDosboxScancode.f10),
    RetroDosboxKey('F11', RetroDosboxScancode.f11),
    RetroDosboxKey('F12', RetroDosboxScancode.f12),
  ];

  /// The keypad matters more than its obscurity suggests: it is the primary
  /// control surface for a large share of DOS flight and space sims.
  static const List<RetroDosboxKey> keypad = [
    RetroDosboxKey('Num 0', RetroDosboxScancode.kp0),
    RetroDosboxKey('Num 1', RetroDosboxScancode.kp1),
    RetroDosboxKey('Num 2', RetroDosboxScancode.kp2),
    RetroDosboxKey('Num 3', RetroDosboxScancode.kp3),
    RetroDosboxKey('Num 4', RetroDosboxScancode.kp4),
    RetroDosboxKey('Num 5', RetroDosboxScancode.kp5),
    RetroDosboxKey('Num 6', RetroDosboxScancode.kp6),
    RetroDosboxKey('Num 7', RetroDosboxScancode.kp7),
    RetroDosboxKey('Num 8', RetroDosboxScancode.kp8),
    RetroDosboxKey('Num 9', RetroDosboxScancode.kp9),
    RetroDosboxKey('Num .', RetroDosboxScancode.kpPeriod),
    RetroDosboxKey('Num +', RetroDosboxScancode.kpPlus),
    RetroDosboxKey('Num -', RetroDosboxScancode.kpMinus),
    RetroDosboxKey('Num *', RetroDosboxScancode.kpMultiply),
    RetroDosboxKey('Num /', RetroDosboxScancode.kpDivide),
    RetroDosboxKey('Num Enter', RetroDosboxScancode.kpEnter),
  ];

  static const List<RetroDosboxKey> editing = [
    RetroDosboxKey('Backspace', RetroDosboxScancode.backspace),
    RetroDosboxKey('Delete', RetroDosboxScancode.delete),
    RetroDosboxKey('Insert', RetroDosboxScancode.insert),
    RetroDosboxKey('Home', RetroDosboxScancode.home),
    RetroDosboxKey('End', RetroDosboxScancode.end),
    RetroDosboxKey('PgUp', RetroDosboxScancode.pageUp),
    RetroDosboxKey('PgDn', RetroDosboxScancode.pageDown),
  ];

  static const List<RetroDosboxKey> symbols = [
    RetroDosboxKey('-', RetroDosboxScancode.minus, shiftLabel: '_'),
    RetroDosboxKey('=', RetroDosboxScancode.equals, shiftLabel: '+'),
    RetroDosboxKey('[', RetroDosboxScancode.leftBracket, shiftLabel: '{'),
    RetroDosboxKey(']', RetroDosboxScancode.rightBracket, shiftLabel: '}'),
    RetroDosboxKey(r'\', RetroDosboxScancode.backslash, shiftLabel: '|'),
    RetroDosboxKey(';', RetroDosboxScancode.semicolon, shiftLabel: ':'),
    RetroDosboxKey("'", RetroDosboxScancode.apostrophe, shiftLabel: '"'),
    RetroDosboxKey('`', RetroDosboxScancode.grave, shiftLabel: '~'),
    RetroDosboxKey(',', RetroDosboxScancode.comma, shiftLabel: '<'),
    RetroDosboxKey('.', RetroDosboxScancode.period, shiftLabel: '>'),
    RetroDosboxKey('/', RetroDosboxScancode.slash, shiftLabel: '?'),
  ];

  /// Ordered groups for the picker UI.
  static const Map<String, List<RetroDosboxKey>> groups = {
    'Common': common,
    'Arrows': arrows,
    'Letters': letters,
    'Numbers': numbers,
    'Function': function,
    'Keypad': keypad,
    'Editing': editing,
    'Symbols': symbols,
  };

  static final Map<int, RetroDosboxKey> _byScancode = {
    for (final group in groups.values)
      for (final key in group) key.scancode: key,
  };

  /// The catalogue entry for a scancode, or null if it is not one we name.
  static RetroDosboxKey? byScancode(int scancode) => _byScancode[scancode];

  /// Human label for a scancode, falling back to the raw number so an
  /// unrecognised binding is still debuggable in the UI rather than blank.
  static String labelFor(int scancode) =>
      _byScancode[scancode]?.label ?? 'Key $scancode';
}
