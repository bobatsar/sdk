// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'context_collection_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(IfElementTest);
  });
}

@reflectiveTest
class IfElementTest extends PatternsResolutionTest {
  test_caseClause() async {
    await assertNoErrorsInCode(r'''
void f(Object x) {
  [if (x case 0) 1 else 2];
}
''');

    final node = findNode.ifElement('if');
    assertResolvedNodeText(node, r'''
IfElement
  ifKeyword: if
  leftParenthesis: (
  condition: SimpleIdentifier
    token: x
    staticElement: self::@function::f::@parameter::x
    staticType: Object
  caseClause: CaseClause
    caseKeyword: case
    guardedPattern: GuardedPattern
      pattern: ConstantPattern
        expression: IntegerLiteral
          literal: 0
          staticType: int
  rightParenthesis: )
  thenElement: IntegerLiteral
    literal: 1
    staticType: int
  elseKeyword: else
  elseElement: IntegerLiteral
    literal: 2
    staticType: int
''');
  }

  test_rewrite_caseClause_pattern() async {
    await assertNoErrorsInCode(r'''
void f(Object x, int Function() a) {
  [if (x case const a()) 0];
}
''');

    final node = findNode.ifElement('if');
    assertResolvedNodeText(node, r'''
IfElement
  ifKeyword: if
  leftParenthesis: (
  condition: SimpleIdentifier
    token: x
    staticElement: self::@function::f::@parameter::x
    staticType: Object
  caseClause: CaseClause
    caseKeyword: case
    guardedPattern: GuardedPattern
      pattern: ConstantPattern
        const: const
        expression: FunctionExpressionInvocation
          function: SimpleIdentifier
            token: a
            staticElement: self::@function::f::@parameter::a
            staticType: int Function()
          argumentList: ArgumentList
            leftParenthesis: (
            rightParenthesis: )
          staticElement: <null>
          staticInvokeType: int Function()
          staticType: int
  rightParenthesis: )
  thenElement: IntegerLiteral
    literal: 0
    staticType: int
''');
  }

  test_rewrite_expression() async {
    await assertNoErrorsInCode(r'''
void f(bool Function() a) {
  [if (a()) 0];
}
''');

    final node = findNode.ifElement('if');
    assertResolvedNodeText(node, r'''
IfElement
  ifKeyword: if
  leftParenthesis: (
  condition: FunctionExpressionInvocation
    function: SimpleIdentifier
      token: a
      staticElement: self::@function::f::@parameter::a
      staticType: bool Function()
    argumentList: ArgumentList
      leftParenthesis: (
      rightParenthesis: )
    staticElement: <null>
    staticInvokeType: bool Function()
    staticType: bool
  rightParenthesis: )
  thenElement: IntegerLiteral
    literal: 0
    staticType: int
''');
  }

  test_rewrite_expression_caseClause() async {
    await assertNoErrorsInCode(r'''
void f(int Function() a) {
  [if (a() case 0) 1];
}
''');

    final node = findNode.ifElement('if');
    assertResolvedNodeText(node, r'''
IfElement
  ifKeyword: if
  leftParenthesis: (
  condition: FunctionExpressionInvocation
    function: SimpleIdentifier
      token: a
      staticElement: self::@function::f::@parameter::a
      staticType: int Function()
    argumentList: ArgumentList
      leftParenthesis: (
      rightParenthesis: )
    staticElement: <null>
    staticInvokeType: int Function()
    staticType: int
  caseClause: CaseClause
    caseKeyword: case
    guardedPattern: GuardedPattern
      pattern: ConstantPattern
        expression: IntegerLiteral
          literal: 0
          staticType: int
  rightParenthesis: )
  thenElement: IntegerLiteral
    literal: 1
    staticType: int
''');
  }

  test_rewrite_whenClause() async {
    await assertNoErrorsInCode(r'''
void f(Object x, bool Function() a) {
  [if (x case 0 when a()) 1];
}
''');

    final node = findNode.ifElement('if');
    assertResolvedNodeText(node, r'''
IfElement
  ifKeyword: if
  leftParenthesis: (
  condition: SimpleIdentifier
    token: x
    staticElement: self::@function::f::@parameter::x
    staticType: Object
  caseClause: CaseClause
    caseKeyword: case
    guardedPattern: GuardedPattern
      pattern: ConstantPattern
        expression: IntegerLiteral
          literal: 0
          staticType: int
      whenClause: WhenClause
        whenKeyword: when
        expression: FunctionExpressionInvocation
          function: SimpleIdentifier
            token: a
            staticElement: self::@function::f::@parameter::a
            staticType: bool Function()
          argumentList: ArgumentList
            leftParenthesis: (
            rightParenthesis: )
          staticElement: <null>
          staticInvokeType: bool Function()
          staticType: bool
  rightParenthesis: )
  thenElement: IntegerLiteral
    literal: 1
    staticType: int
''');
  }

  test_whenClause() async {
    await assertNoErrorsInCode(r'''
void f(Object x) {
  [if (x case 0 when true) 1 else 2];
}
''');

    final node = findNode.ifElement('if');
    assertResolvedNodeText(node, r'''
IfElement
  ifKeyword: if
  leftParenthesis: (
  condition: SimpleIdentifier
    token: x
    staticElement: self::@function::f::@parameter::x
    staticType: Object
  caseClause: CaseClause
    caseKeyword: case
    guardedPattern: GuardedPattern
      pattern: ConstantPattern
        expression: IntegerLiteral
          literal: 0
          staticType: int
      whenClause: WhenClause
        whenKeyword: when
        expression: BooleanLiteral
          literal: true
          staticType: bool
  rightParenthesis: )
  thenElement: IntegerLiteral
    literal: 1
    staticType: int
  elseKeyword: else
  elseElement: IntegerLiteral
    literal: 2
    staticType: int
''');
  }
}
