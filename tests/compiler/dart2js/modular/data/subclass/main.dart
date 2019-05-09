import 'f1.dart';
import 'a/a.dart';

class C2 extends B1 {
  final foo = createA0();
}

main() {
  var buffer = new C2().foo.buffer;

  buffer.write('world! $x');
  print(buffer.toString());
}
