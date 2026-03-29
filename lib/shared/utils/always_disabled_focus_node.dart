import 'package:flutter/material.dart';

/// A [FocusNode] that is always unfocused so a [SearchBar] only responds
/// to [onTap] without opening the keyboard.
class AlwaysDisabledFocusNode extends FocusNode {
  @override
  bool get hasFocus => false;
}
