// A tiny grammar for imp's tests of grammars installed at runtime. After
// changing it, run `tree-sitter generate` here (nix-shell -p tree-sitter)
// and commit src/ with it.
module.exports = grammar({
  name: 'imptest',
  word: $ => $.identifier,
  extras: $ => [/\s/, $.comment],
  rules: {
    source_file: $ => repeat(choice($.function, $.let)),
    function: $ => seq('fn', field('name', $.identifier), $.parameters, $.block),
    parameters: $ => seq('(', optional(seq($.identifier, repeat(seq(',', $.identifier)))), ')'),
    block: $ => seq('{', repeat($.let), '}'),
    let: $ => seq('let', $.identifier, '=', choice($.number, $.string), ';'),
    identifier: _ => /[a-z_]+/,
    number: _ => /\d+/,
    string: _ => /"[^"]*"/,
    comment: _ => /#.*/,
  },
});
