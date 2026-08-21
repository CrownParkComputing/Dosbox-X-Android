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
class DosScancode {
  DosScancode._();

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
class DosKey {
  /// Label drawn on the key cap.
  final String label;

  /// [DosScancode] value sent to the core.
  final int scancode;

  /// Label for the shifted face of the key, drawn small. Presentation only --
  /// shifting is the emulated BIOS's job, not ours, so we never synthesise a
  /// different scancode for it.
  final String? shiftLabel;

  const DosKey(this.label, this.scancode, {this.shiftLabel});
}

/// Keys grouped for the on-screen key picker, mirroring the way the VICE app's
/// C64KeyCatalogue is grouped. "Common" is first and deliberately short: it is
/// the set a DOS game actually needs bound to a touch button.
class DosKeyCatalogue {
  DosKeyCatalogue._();

  static const List<DosKey> common = [
    DosKey('Enter', DosScancode.enter),
    DosKey('Esc', DosScancode.escape),
    DosKey('Space', DosScancode.space),
    DosKey('Ctrl', DosScancode.lctrl),
    DosKey('Alt', DosScancode.lalt),
    DosKey('Shift', DosScancode.lshift),
    DosKey('Tab', DosScancode.tab),
    DosKey('Y', DosScancode.y),
    DosKey('N', DosScancode.n),
  ];

  static const List<DosKey> arrows = [
    DosKey('Up', DosScancode.up),
    DosKey('Down', DosScancode.down),
    DosKey('Left', DosScancode.left),
    DosKey('Right', DosScancode.right),
  ];

  static const List<DosKey> letters = [
    DosKey('A', DosScancode.a),
    DosKey('B', DosScancode.b),
    DosKey('C', DosScancode.c),
    DosKey('D', DosScancode.d),
    DosKey('E', DosScancode.e),
    DosKey('F', DosScancode.f),
    DosKey('G', DosScancode.g),
    DosKey('H', DosScancode.h),
    DosKey('I', DosScancode.i),
    DosKey('J', DosScancode.j),
    DosKey('K', DosScancode.k),
    DosKey('L', DosScancode.l),
    DosKey('M', DosScancode.m),
    DosKey('N', DosScancode.n),
    DosKey('O', DosScancode.o),
    DosKey('P', DosScancode.p),
    DosKey('Q', DosScancode.q),
    DosKey('R', DosScancode.r),
    DosKey('S', DosScancode.s),
    DosKey('T', DosScancode.t),
    DosKey('U', DosScancode.u),
    DosKey('V', DosScancode.v),
    DosKey('W', DosScancode.w),
    DosKey('X', DosScancode.x),
    DosKey('Y', DosScancode.y),
    DosKey('Z', DosScancode.z),
  ];

  static const List<DosKey> numbers = [
    DosKey('1', DosScancode.n1, shiftLabel: '!'),
    DosKey('2', DosScancode.n2, shiftLabel: '@'),
    DosKey('3', DosScancode.n3, shiftLabel: '#'),
    DosKey('4', DosScancode.n4, shiftLabel: r'$'),
    DosKey('5', DosScancode.n5, shiftLabel: '%'),
    DosKey('6', DosScancode.n6, shiftLabel: '^'),
    DosKey('7', DosScancode.n7, shiftLabel: '&'),
    DosKey('8', DosScancode.n8, shiftLabel: '*'),
    DosKey('9', DosScancode.n9, shiftLabel: '('),
    DosKey('0', DosScancode.n0, shiftLabel: ')'),
  ];

  static const List<DosKey> function = [
    DosKey('F1', DosScancode.f1),
    DosKey('F2', DosScancode.f2),
    DosKey('F3', DosScancode.f3),
    DosKey('F4', DosScancode.f4),
    DosKey('F5', DosScancode.f5),
    DosKey('F6', DosScancode.f6),
    DosKey('F7', DosScancode.f7),
    DosKey('F8', DosScancode.f8),
    DosKey('F9', DosScancode.f9),
    DosKey('F10', DosScancode.f10),
    DosKey('F11', DosScancode.f11),
    DosKey('F12', DosScancode.f12),
  ];

  /// The keypad matters more than its obscurity suggests: it is the primary
  /// control surface for a large share of DOS flight and space sims.
  static const List<DosKey> keypad = [
    DosKey('Num 0', DosScancode.kp0),
    DosKey('Num 1', DosScancode.kp1),
    DosKey('Num 2', DosScancode.kp2),
    DosKey('Num 3', DosScancode.kp3),
    DosKey('Num 4', DosScancode.kp4),
    DosKey('Num 5', DosScancode.kp5),
    DosKey('Num 6', DosScancode.kp6),
    DosKey('Num 7', DosScancode.kp7),
    DosKey('Num 8', DosScancode.kp8),
    DosKey('Num 9', DosScancode.kp9),
    DosKey('Num .', DosScancode.kpPeriod),
    DosKey('Num +', DosScancode.kpPlus),
    DosKey('Num -', DosScancode.kpMinus),
    DosKey('Num *', DosScancode.kpMultiply),
    DosKey('Num /', DosScancode.kpDivide),
    DosKey('Num Enter', DosScancode.kpEnter),
  ];

  static const List<DosKey> editing = [
    DosKey('Backspace', DosScancode.backspace),
    DosKey('Delete', DosScancode.delete),
    DosKey('Insert', DosScancode.insert),
    DosKey('Home', DosScancode.home),
    DosKey('End', DosScancode.end),
    DosKey('PgUp', DosScancode.pageUp),
    DosKey('PgDn', DosScancode.pageDown),
  ];

  static const List<DosKey> symbols = [
    DosKey('-', DosScancode.minus, shiftLabel: '_'),
    DosKey('=', DosScancode.equals, shiftLabel: '+'),
    DosKey('[', DosScancode.leftBracket, shiftLabel: '{'),
    DosKey(']', DosScancode.rightBracket, shiftLabel: '}'),
    DosKey(r'\', DosScancode.backslash, shiftLabel: '|'),
    DosKey(';', DosScancode.semicolon, shiftLabel: ':'),
    DosKey("'", DosScancode.apostrophe, shiftLabel: '"'),
    DosKey('`', DosScancode.grave, shiftLabel: '~'),
    DosKey(',', DosScancode.comma, shiftLabel: '<'),
    DosKey('.', DosScancode.period, shiftLabel: '>'),
    DosKey('/', DosScancode.slash, shiftLabel: '?'),
  ];

  /// Ordered groups for the picker UI.
  static const Map<String, List<DosKey>> groups = {
    'Common': common,
    'Arrows': arrows,
    'Letters': letters,
    'Numbers': numbers,
    'Function': function,
    'Keypad': keypad,
    'Editing': editing,
    'Symbols': symbols,
  };

  static final Map<int, DosKey> _byScancode = {
    for (final group in groups.values)
      for (final key in group) key.scancode: key,
  };

  /// The catalogue entry for a scancode, or null if it is not one we name.
  static DosKey? byScancode(int scancode) => _byScancode[scancode];

  /// Human label for a scancode, falling back to the raw number so an
  /// unrecognised binding is still debuggable in the UI rather than blank.
  static String labelFor(int scancode) =>
      _byScancode[scancode]?.label ?? 'Key $scancode';
}
