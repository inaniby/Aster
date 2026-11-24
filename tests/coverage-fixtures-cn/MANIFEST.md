# coverage-fixtures-cn — provenance manifest

Byte-identical extracts of heredoc programs from the cn suite scripts
in `tests/` (same work tree, branch `cn-s1-s2-frontend-fix`). No file
content was edited; the only changes are dedup renames (`__2`, `__3`)
where one suite writes the same path twice with different content
(e.g. `probe.ast` zh then en in cn-embed). Language is a guess for
files without a `// aster:language=` directive (`?` = unknown);
`coverage-checks.sh` runs every fixture with both `--language zh`
and `--language en`, so a wrong guess costs nothing.

Data files the fixtures need (created by the extractor run, same
bytes the suites create): `cn-embed/data.bin` (`A\x01\x02\x03\x04`),
`cn-embed/import/sub/helper.bin` (`Z`). D-2a drafts live in
`d2a/` (copies of `~/workspace/asterui-cn-s1s2/prototypes/d2a/`,
concatenated with the decl-layout stubs into `full-*.ast`).

| suite | line | fixture path | kind | lines | language | note |
|---|---|---|---|---|---|---|
| cn-lexer-checks.sh | 10 | zh.ast | ast | 4 | zh? |  |
| cn-lexer-checks.sh | 45 | aster.proj | proj | 3 | - |  |
| cn-lexer-checks.sh | 56 | aster__2.proj | proj | 3 | - |  |
| cn-parser-checks.sh | 10 | counter-zh.ast | ast | 7 | zh? |  |
| cn-parser-checks.sh | 19 | counter-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 38 | start-zh.ast | ast | 3 | zh? |  |
| cn-parser-checks.sh | 43 | start-en.ast | ast | 4 | en (directive) |  |
| cn-parser-checks.sh | 55 | english-entry-in-zh.ast | ast | 3 | zh? |  |
| cn-parser-checks.sh | 67 | package-zh.ast | ast | 7 | zh? |  |
| cn-parser-checks.sh | 76 | package-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 94 | package-late.ast | ast | 4 | zh? |  |
| cn-parser-checks.sh | 106 | import-empty-alias.ast | ast | 4 | zh? |  |
| cn-parser-checks.sh | 118 | if-zh.ast | ast | 11 | zh? |  |
| cn-parser-checks.sh | 131 | if-en.ast | ast | 12 | en (directive) |  |
| cn-parser-checks.sh | 151 | count-zh.ast | ast | 7 | zh? |  |
| cn-parser-checks.sh | 160 | count-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 176 | count-no-counter.ast | ast | 6 | zh? |  |
| cn-parser-checks.sh | 187 | match-zh.ast | ast | 13 | zh? |  |
| cn-parser-checks.sh | 202 | match-en.ast | ast | 14 | en (directive) |  |
| cn-parser-checks.sh | 225 | mismatch.ast | ast | 3 | zh? |  |
| cn-parser-checks.sh | 235 | count-mismatch.ast | ast | 5 | zh? |  |
| cn-parser-checks.sh | 248 | mixed.ast | ast | 3 | zh? |  |
| cn-parser-checks.sh | 259 | reserved-name.ast | ast | 3 | zh? |  |
| cn-parser-checks.sh | 269 | array-zh.ast | ast | 5 | zh? |  |
| cn-parser-checks.sh | 276 | array-en.ast | ast | 6 | en (directive) |  |
| cn-parser-checks.sh | 291 | foreach-zh.ast | ast | 10 | zh? |  |
| cn-parser-checks.sh | 303 | foreach-en.ast | ast | 11 | en (directive) |  |
| cn-parser-checks.sh | 323 | enumloop-zh.ast | ast | 6 | zh? |  |
| cn-parser-checks.sh | 331 | enumloop-en.ast | ast | 7 | en (directive) |  |
| cn-parser-checks.sh | 346 | float-zh.ast | ast | 5 | zh? |  |
| cn-parser-checks.sh | 353 | float-en.ast | ast | 6 | en (directive) |  |
| cn-parser-checks.sh | 368 | cast-zh.ast | ast | 5 | zh? |  |
| cn-parser-checks.sh | 375 | cast-en.ast | ast | 6 | en (directive) |  |
| cn-parser-checks.sh | 390 | struct-zh.ast | ast | 15 | zh? |  |
| cn-parser-checks.sh | 407 | struct-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 424 | struct-array-field-zh.ast | ast | 8 | zh? |  |
| cn-parser-checks.sh | 434 | struct-array-field-en.ast | ast | 7 | en (directive) |  |
| cn-parser-checks.sh | 450 | struct-array-element-zh.ast | ast | 8 | zh? |  |
| cn-parser-checks.sh | 460 | struct-array-element-en.ast | ast | 6 | en (directive) |  |
| cn-parser-checks.sh | 474 | struct-literal-zh.ast | ast | 8 | zh? |  |
| cn-parser-checks.sh | 484 | struct-literal-en.ast | ast | 6 | en (directive) |  |
| cn-parser-checks.sh | 498 | enum-zh.ast | ast | 9 | zh? |  |
| cn-parser-checks.sh | 509 | enum-en.ast | ast | 10 | en (directive) |  |
| cn-parser-checks.sh | 526 | enum-braces-zh.ast | ast | 4 | zh? |  |
| cn-parser-checks.sh | 538 | restricted-class-zh.ast | ast | 11 | zh? |  |
| cn-parser-checks.sh | 551 | restricted-class-en.ast | ast | 12 | en (directive) |  |
| cn-parser-checks.sh | 571 | restricted-class-old-en.ast | ast | 10 | en (directive) |  |
| cn-parser-checks.sh | 590 | restricted-top-level-old-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 607 | closure-zh.ast | ast | 20 | zh? |  |
| cn-parser-checks.sh | 629 | closure-en.ast | ast | 21 | en (directive) |  |
| cn-parser-checks.sh | 658 | closure-reference-capture.ast | ast | 7 | zh? |  |
| cn-parser-checks.sh | 674 | closure-type-zh.ast | ast | 7 | zh? |  |
| cn-parser-checks.sh | 683 | closure-type-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 699 | closure-type-arrow-zh.ast | ast | 4 | zh? |  |
| cn-parser-checks.sh | 712 | closure-type-arrow-en.ast | ast | 5 | en (directive) |  |
| cn-parser-checks.sh | 726 | duplicate-capture-zh.ast | ast | 6 | zh? |  |
| cn-parser-checks.sh | 741 | duplicate-capture-en.ast | ast | 7 | en (directive) |  |
| cn-parser-checks.sh | 757 | omitted-void-zh.ast | ast | 9 | zh? |  |
| cn-parser-checks.sh | 768 | omitted-void-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 784 | class-field-initializer-zh.ast | ast | 4 | zh? |  |
| cn-parser-checks.sh | 790 | class-field-initializer-en.ast | ast | 5 | en (directive) |  |
| cn-parser-checks.sh | 803 | private-top-level-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 816 | static-field-zh.ast | ast | 7 | zh? |  |
| cn-parser-checks.sh | 825 | static-field-en.ast | ast | 6 | en (directive) |  |
| cn-parser-checks.sh | 839 | interface-inheritance-zh.ast | ast | 9 | zh? |  |
| cn-parser-checks.sh | 850 | interface-inheritance-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 880 | dot-type-en.ast | ast | 3 | en (directive) |  |
| cn-parser-checks.sh | 889 | alias-import-zh.ast | ast | 6 | zh? |  |
| cn-parser-checks.sh | 900 | alias-import-en.ast | ast | 4 | en (directive) |  |
| cn-parser-checks.sh | 912 | late-literal-zh.ast | ast | 8 | zh? |  |
| cn-parser-checks.sh | 924 | late-construct-en.ast | ast | 8 | en (directive) |  |
| cn-parser-checks.sh | 938 | ternary-zh.ast | ast | 4 | zh? |  |
| cn-parser-checks.sh | 946 | ternary-en.ast | ast | 2 | en (directive) |  |
| cn-parser-checks.sh | 954 | switch-default-en.ast | ast | 2 | en (directive) |  |
| cn-parser-checks.sh | 963 | multidim-var-zh.ast | ast | 4 | zh? |  |
| cn-parser-checks.sh | 975 | multidim-param-en.ast | ast | 3 | en (directive) |  |
| cn-parser-checks.sh | 989 | annotation-zh-private.ast | ast | 7 | zh? |  |
| cn-parser-checks.sh | 1004 | annotation-en-hidden.ast | ast | 6 | en (directive) |  |
| cn-parser-checks.sh | 1020 | empty-zh.ast | ast | 8 | zh? |  |
| cn-parser-checks.sh | 1032 | empty-switch-en.ast | ast | 2 | en (directive) |  |
| cn-parser-checks.sh | 1040 | reserved-field-zh.ast | ast | 6 | zh? |  |
| cn-ast-equiv-checks.sh | 17 | counter-zh.ast | ast | 8 | zh (directive) |  |
| cn-ast-equiv-checks.sh | 27 | counter-en.ast | ast | 8 | en (directive) |  |
| cn-ast-equiv-checks.sh | 54 | omit-zh.ast | ast | 7 | zh (directive) |  |
| cn-ast-equiv-checks.sh | 63 | omit-en.ast | ast | 5 | en (directive) |  |
| cn-backend-checks.sh | 22 | core-zh.ast | ast | 20 | zh (directive) |  |
| cn-backend-checks.sh | 44 | core-en.ast | ast | 19 | en? |  |
| cn-backend-checks.sh | 69 | aster.proj | proj | 3 | - |  |
| cn-backend-checks.sh | 78 | omitted-void-zh.ast | ast | 14 | zh (directive) |  |
| cn-backend-checks.sh | 94 | omitted-void-en.ast | ast | 14 | en (directive) |  |
| cn-backend-checks.sh | 118 | extern-zh.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 125 | extern-en.ast | ast | 5 | en (directive) |  |
| cn-backend-checks.sh | 138 | extern-global-zh.ast | ast | 6 | zh (directive) |  |
| cn-backend-checks.sh | 146 | extern-global-en.ast | ast | 6 | en (directive) |  |
| cn-backend-checks.sh | 160 | extern-global-array-zh.ast | ast | 6 | zh (directive) |  |
| cn-backend-checks.sh | 168 | extern-global-array-en.ast | ast | 6 | en (directive) |  |
| cn-backend-checks.sh | 182 | extern-global-fn-zh.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 189 | extern-global-fn-en.ast | ast | 5 | en (directive) |  |
| cn-backend-checks.sh | 202 | extern-global-string-zh.ast | ast | 9 | zh (directive) |  |
| cn-backend-checks.sh | 213 | extern-global-string-en.ast | ast | 9 | en (directive) |  |
| cn-backend-checks.sh | 230 | extern-global-missing-map.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 246 | extern-global-init.ast | ast | 3 | en (directive) |  |
| cn-backend-checks.sh | 261 | extern-missing-map.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 277 | extern-empty-map.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 298 | extern-nonascii-map.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 328 | cimp4-helper-cn.ast | ast | 46 | zh (directive) |  |
| cn-backend-checks.sh | 398 | cimp4-driver-cn.ast | ast | 27 | zh (directive) |  |
| cn-backend-checks.sh | 508 | cimp4-driver-alias.ast | ast | 23 | zh (directive) |  |
| cn-backend-checks.sh | 552 | wide-match-zh.ast | ast | 47 | zh (directive) |  |
| cn-backend-checks.sh | 601 | wide-match-en.ast | ast | 46 | en? |  |
| cn-backend-checks.sh | 660 | enum-match-zh.ast | ast | 38 | zh (directive) |  |
| cn-backend-checks.sh | 700 | enum-match-en.ast | ast | 31 | en (directive) |  |
| cn-backend-checks.sh | 744 | truthiness-zh.ast | ast | 65 | zh (directive) |  |
| cn-backend-checks.sh | 811 | truthiness-en.ast | ast | 62 | en (directive) |  |
| cn-backend-checks.sh | 887 | flow.ast | ast | 25 | zh (directive) |  |
| cn-backend-checks.sh | 924 | zero-step.ast | ast | 7 | zh (directive) |  |
| cn-backend-checks.sh | 939 | dynamic-step.ast | ast | 14 | zh (directive) |  |
| cn-backend-checks.sh | 964 | dynamic-zero-step.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 987 | large-step.ast | ast | 7 | zh (directive) |  |
| cn-backend-checks.sh | 1002 | duplicate-match.ast | ast | 10 | zh (directive) |  |
| cn-backend-checks.sh | 1020 | nonconstant-match.ast | ast | 9 | zh (directive) |  |
| cn-backend-checks.sh | 1037 | out-of-range-match.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1053 | bool-match.ast | ast | 9 | zh (directive) |  |
| cn-backend-checks.sh | 1070 | u8-out-of-range-match.ast | ast | 9 | zh (directive) |  |
| cn-backend-checks.sh | 1087 | unknown-match-subject.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1104 | write-counter.ast | ast | 7 | zh (directive) |  |
| cn-backend-checks.sh | 1119 | address-counter.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1136 | invalid.ast | ast | 4 | zh (directive) |  |
| cn-backend-checks.sh | 1148 | struct-if.ast | ast | 11 | zh (directive) |  |
| cn-backend-checks.sh | 1167 | struct-while.ast | ast | 9 | en (directive) |  |
| cn-backend-checks.sh | 1184 | range-match-zh.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1200 | range-match-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 1227 | arrays.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1246 | array-length-mismatch.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 1260 | foreach-zh.ast | ast | 13 | zh (directive) |  |
| cn-backend-checks.sh | 1275 | foreach-en.ast | ast | 13 | en (directive) |  |
| cn-backend-checks.sh | 1301 | foreach-read-only.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1317 | foreach-index-read-only.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1334 | string-zh.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1344 | string-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 1357 | string-native.ast | ast | 4 | en? |  |
| cn-backend-checks.sh | 1372 | string-default.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1391 | string-return.ast | ast | 10 | zh (directive) |  |
| cn-backend-checks.sh | 1412 | string-nul.ast | ast | 4 | zh (directive) |  |
| cn-backend-checks.sh | 1424 | string-view.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 1438 | default-scalars.ast | ast | 36 | zh (directive) |  |
| cn-backend-checks.sh | 1484 | default-void.ast | ast | 5 | zh (directive) |  |
| cn-backend-checks.sh | 1498 | scalar-casts.ast | ast | 16 | zh (directive) |  |
| cn-backend-checks.sh | 1517 | scalar-casts-en.ast | ast | 10 | en (directive) |  |
| cn-backend-checks.sh | 1538 | bad-cast-arity.ast | ast | 4 | zh (directive) |  |
| cn-backend-checks.sh | 1552 | struct-defaults-zh.ast | ast | 40 | zh (directive) |  |
| cn-backend-checks.sh | 1594 | struct-defaults-en.ast | ast | 16 | en (directive) |  |
| cn-backend-checks.sh | 1623 | struct-void-field.ast | ast | 7 | zh (directive) |  |
| cn-backend-checks.sh | 1638 | struct-literal-zh.ast | ast | 16 | zh (directive) |  |
| cn-backend-checks.sh | 1656 | struct-literal-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 1677 | struct-literal-arity.ast | ast | 9 | zh (directive) |  |
| cn-backend-checks.sh | 1694 | struct-array-zh.ast | ast | 17 | zh (directive) |  |
| cn-backend-checks.sh | 1713 | struct-array-en.ast | ast | 10 | en (directive) |  |
| cn-backend-checks.sh | 1737 | default-read-zh.ast | ast | 23 | zh (directive) |  |
| cn-backend-checks.sh | 1762 | default-read-en.ast | ast | 11 | en (directive) |  |
| cn-backend-checks.sh | 1780 | struct-array-element-zh.ast | ast | 18 | zh (directive) |  |
| cn-backend-checks.sh | 1800 | struct-array-element-en.ast | ast | 10 | en (directive) |  |
| cn-backend-checks.sh | 1824 | enumloop-zh.ast | ast | 81 | zh (directive) |  |
| cn-backend-checks.sh | 1907 | enumloop-en.ast | ast | 41 | en (directive) |  |
| cn-backend-checks.sh | 1961 | enumloop-scalar.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 1977 | stable-zh.ast | ast | 30 | zh (directive) |  |
| cn-backend-checks.sh | 2009 | stable-en.ast | ast | 22 | en (directive) |  |
| cn-backend-checks.sh | 2055 | signed-narrow-zh.ast | ast | 115 | zh (directive) |  |
| cn-backend-checks.sh | 2172 | signed-narrow-en.ast | ast | 55 | en (directive) |  |
| cn-backend-checks.sh | 2244 | native-signed-narrow.ast | ast | 9 | en? |  |
| cn-backend-checks.sh | 2267 | signed-narrow-overflow.ast | SKIPPED | 2 | - | skipped: expected-output / C probe / $ template |
| cn-backend-checks.sh | 2278 | closure-unknown-capture.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 2295 | closure-uncaptured-body.ast | ast | 9 | zh (directive) |  |
| cn-backend-checks.sh | 2313 | closure-global-capture.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 2331 | closure-large-env.ast | ast | 11 | en (directive) |  |
| cn-backend-checks.sh | 2352 | closure-this-outside.ast | ast | 7 | en (directive) |  |
| cn-backend-checks.sh | 2369 | closure-valid-capture.ast | ast | 9 | en (directive) |  |
| cn-backend-checks.sh | 2383 | closure-zero-en.ast | ast | 7 | en (directive) |  |
| cn-backend-checks.sh | 2395 | closure-zero-zh.ast | ast | 7 | zh (directive) |  |
| cn-backend-checks.sh | 2407 | closure-field-en.ast | ast | 9 | en (directive) |  |
| cn-backend-checks.sh | 2421 | closure-field-zh.ast | ast | 11 | zh (directive) |  |
| cn-backend-checks.sh | 2437 | closure-array-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 2450 | closure-array-zh.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 2463 | closure-array-capture-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 2476 | closure-array-capture-zh.ast | ast | 8 | zh (directive) |  |
| cn-backend-checks.sh | 2489 | closure-callback-adapter-en.ast | ast | 16 | en (directive) |  |
| cn-backend-checks.sh | 2510 | closure-callback-adapter-zh.ast | ast | 13 | zh (directive) |  |
| cn-backend-checks.sh | 2528 | closure-callback-member-en.ast | ast | 14 | en (directive) |  |
| cn-backend-checks.sh | 2547 | closure-callback-member-zh.ast | ast | 14 | zh (directive) |  |
| cn-backend-checks.sh | 2566 | closure-callback-field-en.ast | ast | 12 | en (directive) |  |
| cn-backend-checks.sh | 2583 | closure-callback-array-zh.ast | ast | 11 | zh (directive) |  |
| cn-backend-checks.sh | 2599 | closure-callback-delayed-en.ast | ast | 32 | en (directive) |  |
| cn-backend-checks.sh | 2636 | closure-callback-delayed-zh.ast | ast | 38 | zh (directive) |  |
| cn-backend-checks.sh | 2679 | closure-callback-nested-en.ast | ast | 12 | en (directive) |  |
| cn-backend-checks.sh | 2696 | closure-callback-nested-zh.ast | ast | 14 | zh (directive) |  |
| cn-backend-checks.sh | 2715 | closure-callback-condition-en.ast | ast | 14 | en (directive) |  |
| cn-backend-checks.sh | 2734 | closure-callback-condition-zh.ast | ast | 14 | zh (directive) |  |
| cn-backend-checks.sh | 2753 | closure-callback-while-en.ast | ast | 17 | en (directive) |  |
| cn-backend-checks.sh | 2775 | closure-callback-while-zh.ast | ast | 17 | zh (directive) |  |
| cn-backend-checks.sh | 2797 | closure-callback-count-en.ast | ast | 16 | en (directive) |  |
| cn-backend-checks.sh | 2818 | closure-callback-count-zh.ast | ast | 16 | zh (directive) |  |
| cn-backend-checks.sh | 2839 | closure-callback-match-en.ast | ast | 15 | en (directive) |  |
| cn-backend-checks.sh | 2859 | closure-callback-match-zh.ast | ast | 15 | zh (directive) |  |
| cn-backend-checks.sh | 2879 | closure-callback-struct-return-en.ast | ast | 13 | en (directive) |  |
| cn-backend-checks.sh | 2902 | closure-callback-struct-return-zh.ast | ast | 15 | zh (directive) |  |
| cn-backend-checks.sh | 2927 | closure-callback-void-nested-en.ast | ast | 11 | en (directive) |  |
| cn-backend-checks.sh | 2948 | closure-callback-void-nested-zh.ast | ast | 13 | zh (directive) |  |
| cn-backend-checks.sh | 2971 | closure-callback-wrong-user-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 2989 | closure-callback-wrong-user-zh.ast | ast | 10 | zh (directive) |  |
| cn-backend-checks.sh | 3009 | closure-callback-plain-function-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 3022 | closure-callback-plain-function-zh.ast | ast | 10 | zh (directive) |  |
| cn-backend-checks.sh | 3072 | closure-valid-capture-zh.ast | ast | 9 | zh (directive) |  |
| cn-backend-checks.sh | 3170 | class-enum-public-en.ast | ast | 15 | en (directive) |  |
| cn-backend-checks.sh | 3187 | class-enum-public-zh.ast | ast | 19 | zh (directive) |  |
| cn-backend-checks.sh | 3220 | class-enum-null-en.ast | ast | 7 | en (directive) |  |
| cn-backend-checks.sh | 3229 | class-enum-null-zh.ast | ast | 11 | zh (directive) |  |
| cn-backend-checks.sh | 3258 | global-string-array-en.ast | ast | 10 | en (directive) |  |
| cn-backend-checks.sh | 3270 | global-string-array-zh.ast | ast | 14 | zh (directive) |  |
| cn-backend-checks.sh | 3301 | global-string-array-bad.ast | ast | 3 | en (directive) |  |
| cn-backend-checks.sh | 3314 | global-struct-array-en.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 3324 | global-struct-array-zh.ast | ast | 11 | zh (directive) |  |
| cn-backend-checks.sh | 3353 | global-struct-array-string-field.ast | ast | 4 | en (directive) |  |
| cn-backend-checks.sh | 3369 | array-parameter-en.ast | ast | 15 | en (directive) |  |
| cn-backend-checks.sh | 3386 | array-parameter-zh.ast | ast | 23 | zh (directive) |  |
| cn-backend-checks.sh | 3426 | array-parameter-type-mismatch.ast | ast | 6 | en (directive) |  |
| cn-backend-checks.sh | 3443 | array-parameter-length-mismatch.ast | ast | 6 | en (directive) |  |
| cn-backend-checks.sh | 3461 | class-array-parameter-length-mismatch.ast | ast | 8 | en (directive) |  |
| cn-backend-checks.sh | 3481 | interface-array-parameter-length-mismatch.ast | ast | 12 | en (directive) |  |
| cn-backend-checks.sh | 3505 | parent-constructor-array-length-mismatch.ast | ast | 14 | en (directive) |  |
| cn-backend-checks.sh | 3531 | array-parameter-multidimensional.ast | ast | 3 | en (directive) |  |
| cn-backend-checks.sh | 3546 | class-array-parameter-en.ast | ast | 14 | en (directive) |  |
| cn-backend-checks.sh | 3562 | class-array-parameter-zh.ast | ast | 18 | zh (directive) |  |
| cn-backend-checks.sh | 3602 | c3-lib.ast | ast | 28 | zh (directive) |  |
| cn-backend-checks.sh | 3632 | c3-main.ast | ast | 14 | en? |  |
| cn-backend-checks.sh | 3670 | c2-zh.ast | ast | 66 | zh (directive) |  |
| cn-backend-checks.sh | 3738 | c2-en.ast | ast | 44 | en (directive) |  |
| cn-module-checks.sh | 10 | app/start-zh.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 15 | app/start-en.ast | ast | 4 | en (directive) |  |
| cn-module-checks.sh | 30 | project/aster.proj | proj | 6 | - |  |
| cn-module-checks.sh | 38 | project/src/main.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 43 | project/src/helper.ast | ast | 4 | en (directive) |  |
| cn-module-checks.sh | 75 | project-external/aster.proj | proj | 5 | - |  |
| cn-module-checks.sh | 82 | project-external-packages/math.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 89 | project-external/src/main.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 115 | external-abi/packages/text.ast | ast | 3 | zh (directive) |  |
| cn-module-checks.sh | 120 | external-abi/main.ast | ast | 5 | zh (directive) |  |
| cn-module-checks.sh | 136 | external-global-abi/packages/counter.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 143 | external-global-abi/main.ast | ast | 6 | zh (directive) |  |
| cn-module-checks.sh | 166 | test-project/aster.proj | proj | 6 | - |  |
| cn-module-checks.sh | 174 | test-project/src/lib.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 179 | test-project/tests/basic.ast | ast | 4 | en (directive) |  |
| cn-module-checks.sh | 208 | test-project/test-packages/helper.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 215 | test-project/tests/basic__2.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 237 | test-collision/aster.proj | proj | 6 | - |  |
| cn-module-checks.sh | 245 | test-collision/tests/one/same.ast | ast | 4 | en (directive) |  |
| cn-module-checks.sh | 251 | test-collision/tests/two/same.ast | ast | 4 | en (directive) |  |
| cn-module-checks.sh | 269 | packages/calc-zh.ast | ast | 6 | zh (directive) |  |
| cn-module-checks.sh | 277 | packages/calc-en.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 284 | app/main.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 298 | packages/math-zh.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 304 | packages/math-en.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 311 | app/math-zh.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 317 | app/math-en.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 334 | packages/oop-core.ast | ast | 65 | zh? |  |
| cn-module-checks.sh | 401 | packages/interface-base.ast | ast | 8 | en (directive) |  |
| cn-module-checks.sh | 411 | packages/interface-child.ast | ast | 13 | en (directive) |  |
| cn-module-checks.sh | 426 | packages/restricted-interface.ast | ast | 9 | en (directive) |  |
| cn-module-checks.sh | 437 | packages/function-signature-interface.ast | ast | 8 | en (directive) |  |
| cn-module-checks.sh | 447 | packages/oop-callback-en.ast | ast | 76 | en (directive) |  |
| cn-module-checks.sh | 525 | packages/oop-struct-en.ast | ast | 18 | en (directive) |  |
| cn-module-checks.sh | 545 | app/oop-import.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 559 | app/callback-array-import-zh.ast | ast | 7 | zh? |  |
| cn-module-checks.sh | 568 | app/callback-array-import-en.ast | ast | 8 | en (directive) |  |
| cn-module-checks.sh | 591 | app/hidden-method-value.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 607 | app/inherited-callback-import-en.ast | ast | 8 | en (directive) |  |
| cn-module-checks.sh | 617 | app/inherited-callback-import-zh.ast | ast | 9 | zh? |  |
| cn-module-checks.sh | 628 | app/interface-callback-import-en.ast | ast | 4 | en (directive) |  |
| cn-module-checks.sh | 634 | app/interface-callback-import-zh.ast | ast | 7 | zh? |  |
| cn-module-checks.sh | 669 | app/interface-inheritance-import-en.ast | ast | 11 | en (directive) |  |
| cn-module-checks.sh | 682 | app/interface-inheritance-import-zh.ast | ast | 27 | zh? |  |
| cn-module-checks.sh | 724 | app/cross-package-interface-inheritance-en.ast | ast | 13 | en (directive) |  |
| cn-module-checks.sh | 739 | app/cross-package-interface-inheritance-zh.ast | ast | 23 | zh? |  |
| cn-module-checks.sh | 778 | packages/array-api.ast | ast | 12 | en (directive) |  |
| cn-module-checks.sh | 792 | app/array-import.ast | ast | 20 | zh (directive) |  |
| cn-module-checks.sh | 822 | app/hidden-static-callback.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 837 | app/restricted-static-callback.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 852 | app/restricted-instance-callback-array.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 868 | app/restricted-field.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 883 | app/restricted-static-field.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 898 | app/missing-interface-method.ast | ast | 6 | zh? |  |
| cn-module-checks.sh | 917 | app/restricted-interface-implementation.ast | ast | 3 | en (directive) |  |
| cn-module-checks.sh | 932 | app/function-signature-interface.ast | ast | 3 | en (directive) |  |
| cn-module-checks.sh | 947 | packages/state.ast | ast | 7 | zh? |  |
| cn-module-checks.sh | 956 | app/state.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 967 | packages/hidden-global.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 972 | app/hidden-global.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 985 | packages/hidden-type.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 991 | app/hidden-type.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 1005 | packages/restricted-global-a.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 1010 | packages/restricted-global-b.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1016 | app/restricted-global.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1030 | packages/point.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1036 | packages/point-api.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 1043 | app/types.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1053 | packages/secret.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 1060 | app/hidden.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1073 | packages/restricted-a.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 1080 | packages/restricted-b.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1086 | app/restricted.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1099 | packages/cycle-a.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 1106 | packages/cycle-b.ast | ast | 5 | zh? |  |
| cn-module-checks.sh | 1113 | app/cycle.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1127 | packages-conflict/alias-a.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1133 | packages-conflict/alias-b.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1139 | app/alias-conflict.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1154 | packages-alias-root-a/alias-a.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1160 | packages-alias-root-b/alias-b.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1174 | packages-mismatch/alias-mismatch-a.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1180 | packages-mismatch/alias-mismatch-b.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1186 | app/alias-mismatch.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1210 | bp1/base.ast | ast | 3 | en? |  |
| cn-module-checks.sh | 1215 | bp1/lib.ast | ast | 7 | en? |  |
| cn-module-checks.sh | 1224 | bp1/main_en.ast | ast | 5 | en (directive) |  |
| cn-module-checks.sh | 1240 | bp1-zh/aster.proj | proj | 4 | - |  |
| cn-module-checks.sh | 1246 | bp1-zh/src/main.ast | ast | 5 | zh (directive) |  |
| cn-module-checks.sh | 1253 | bp1-zh/src/helper.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 1271 | bp1-mixed/aster.proj | proj | 6 | - |  |
| cn-module-checks.sh | 1279 | bp1-mixed/src/fw_en.ast | ast | 3 | en? |  |
| cn-module-checks.sh | 1284 | bp1-mixed/src/app_zh.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1290 | bp1-mixed/src/helper_zh.ast | ast | 4 | zh? |  |
| cn-module-checks.sh | 1296 | bp1-mixed/src/base_zh.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 1325 | bp1-neg/aster.proj | proj | 5 | - |  |
| cn-module-checks.sh | 1332 | bp1-neg/bad.ast | ast | 4 | zh (directive) |  |
| cn-module-checks.sh | 1338 | bp1-neg/main.ast | ast | 3 | zh? |  |
| cn-module-checks.sh | 1347 | bp1-neg/aster__2.proj | proj | 5 | - |  |
| cn-constructor-checks.sh | 22 | constructor-zh.ast | ast | 102 | zh (directive) |  |
| cn-constructor-checks.sh | 127 | constructor-en.ast | ast | 81 | en (directive) |  |
| cn-constructor-checks.sh | 225 | packages/model.ast | ast | 19 | en (directive) |  |
| cn-constructor-checks.sh | 246 | app/import.ast | ast | 5 | zh (directive) |  |
| cn-constructor-checks.sh | 258 | app/hidden-import.ast | ast | 6 | zh (directive) |  |
| cn-constructor-checks.sh | 278 | multiple-constructors.ast | ast | 12 | zh (directive) |  |
| cn-constructor-checks.sh | 299 | nonvoid-constructor.ast | ast | 10 | zh (directive) |  |
| cn-constructor-checks.sh | 319 | wrong-arity.ast | ast | 10 | zh (directive) |  |
| cn-constructor-checks.sh | 342 | manual-call.ast | ast | 10 | zh (directive) |  |
| cn-constructor-checks.sh | 362 | base-arity.ast | ast | 11 | zh (directive) |  |
| cn-constructor-checks.sh | 383 | base-arity-mismatch.ast | ast | 15 | zh (directive) |  |
| cn-constructor-checks.sh | 408 | misplaced-super.ast | ast | 11 | zh (directive) |  |
| cn-constructor-checks.sh | 429 | unbuilt-parent-argument.ast | ast | 15 | zh (directive) |  |
| cn-constructor-checks.sh | 453 | wrong-field-array-length.ast | ast | 7 | zh (directive) |  |
| cn-constructor-checks.sh | 470 | unbuilt-field-initializer.ast | ast | 7 | zh (directive) |  |
| cn-constructor-checks.sh | 486 | field-type-mismatch-zh.ast | ast | 7 | zh (directive) |  |
| cn-constructor-checks.sh | 495 | field-type-mismatch-en.ast | ast | 5 | en (directive) |  |
| cn-constructor-checks.sh | 519 | field-narrowing.ast | ast | 7 | zh (directive) |  |
| cn-constructor-checks.sh | 536 | field-class-mismatch.ast | ast | 11 | zh (directive) |  |
| cn-constructor-checks.sh | 560 | field-function-mismatch.ast | ast | 8 | zh (directive) |  |
| cn-constructor-checks.sh | 578 | field-array-type-mismatch.ast | ast | 7 | zh (directive) |  |
| cn-constructor-checks.sh | 598 | field-access-zh.ast | ast | 11 | zh (directive) |  |
| cn-constructor-checks.sh | 611 | field-access-en.ast | ast | 9 | en (directive) |  |
| cn-interface-checks.sh | 22 | interface-zh.ast | ast | 48 | zh (directive) |  |
| cn-interface-checks.sh | 73 | interface-en.ast | ast | 30 | en? |  |
| cn-interface-checks.sh | 109 | array-parameter-interface-zh.ast | ast | 21 | zh (directive) |  |
| cn-interface-checks.sh | 132 | array-parameter-interface-en.ast | ast | 17 | en (directive) |  |
| cn-interface-checks.sh | 159 | omitted-void-interface-zh.ast | ast | 20 | zh (directive) |  |
| cn-interface-checks.sh | 181 | omitted-void-interface-en.ast | ast | 16 | en (directive) |  |
| cn-interface-checks.sh | 219 | interface-storage-zh.ast | ast | 28 | zh (directive) |  |
| cn-interface-checks.sh | 249 | interface-storage-en.ast | ast | 26 | en (directive) |  |
| cn-interface-checks.sh | 299 | null-interface-zh.ast | ast | 13 | zh (directive) |  |
| cn-interface-checks.sh | 314 | null-interface-en.ast | ast | 11 | en (directive) |  |
| cn-interface-checks.sh | 327 | null-returned-interface-zh.ast | ast | 15 | zh (directive) |  |
| cn-interface-checks.sh | 344 | null-returned-interface-en.ast | ast | 9 | en (directive) |  |
| cn-interface-checks.sh | 374 | packages/chinese.ast | ast | 10 | zh (directive) |  |
| cn-interface-checks.sh | 386 | app/call-chinese.ast | ast | 6 | en (directive) |  |
| cn-interface-checks.sh | 400 | packages/english.ast | ast | 8 | en (directive) |  |
| cn-interface-checks.sh | 410 | app/call-english.ast | ast | 6 | zh (directive) |  |
| cn-interface-checks.sh | 427 | non-implementer.ast | ast | 10 | zh (directive) |  |
| cn-interface-checks.sh | 446 | unknown-interface-method.ast | ast | 8 | zh (directive) |  |
| cn-interface-checks.sh | 463 | mismatched-interface-implementation.ast | ast | 12 | zh (directive) |  |
| cn-interface-checks.sh | 486 | interface-compare.ast | ast | 8 | zh (directive) |  |
| cn-override-checks.sh | 22 | override-zh.ast | ast | 55 | zh (directive) |  |
| cn-override-checks.sh | 80 | override-en.ast | ast | 33 | en (directive) |  |
| cn-override-checks.sh | 131 | static-fields-zh.ast | ast | 29 | zh (directive) |  |
| cn-override-checks.sh | 163 | static-fields-en.ast | ast | 26 | en (directive) |  |
| cn-override-checks.sh | 210 | static-struct-field-zh.ast | ast | 26 | zh (directive) |  |
| cn-override-checks.sh | 239 | static-struct-field-en.ast | ast | 20 | en (directive) |  |
| cn-override-checks.sh | 283 | static-function-field-zh.ast | ast | 17 | zh (directive) |  |
| cn-override-checks.sh | 303 | static-function-field-en.ast | ast | 10 | en (directive) |  |
| cn-override-checks.sh | 337 | null-class-zh.ast | ast | 10 | zh (directive) |  |
| cn-override-checks.sh | 350 | null-class-en.ast | ast | 8 | en (directive) |  |
| cn-override-checks.sh | 377 | null-returned-class-zh.ast | ast | 12 | zh (directive) |  |
| cn-override-checks.sh | 392 | null-returned-class-en.ast | ast | 6 | en (directive) |  |
| cn-override-checks.sh | 418 | null-class-field-zh.ast | ast | 8 | zh (directive) |  |
| cn-override-checks.sh | 429 | null-class-field-en.ast | ast | 6 | en (directive) |  |
| cn-override-checks.sh | 438 | null-class-field-write-zh.ast | ast | 9 | zh (directive) |  |
| cn-override-checks.sh | 450 | null-class-field-write-en.ast | ast | 7 | en (directive) |  |
| cn-override-checks.sh | 460 | null-class-field-call-zh.ast | ast | 8 | zh (directive) |  |
| cn-override-checks.sh | 471 | null-class-field-call-en.ast | ast | 6 | en (directive) |  |
| cn-override-checks.sh | 480 | null-class-returned-field-zh.ast | ast | 10 | zh (directive) |  |
| cn-override-checks.sh | 493 | null-class-returned-field-en.ast | ast | 4 | en (directive) |  |
| cn-override-checks.sh | 500 | null-class-field-array-zh.ast | ast | 8 | zh (directive) |  |
| cn-override-checks.sh | 511 | null-class-field-array-en.ast | ast | 6 | en (directive) |  |
| cn-override-checks.sh | 520 | null-class-field-array-write-zh.ast | ast | 9 | zh (directive) |  |
| cn-override-checks.sh | 532 | null-class-field-array-write-en.ast | ast | 7 | en (directive) |  |
| cn-override-checks.sh | 561 | static-function-array-en.ast | ast | 11 | en (directive) |  |
| cn-override-checks.sh | 588 | static-function-array-zh.ast | ast | 15 | zh (directive) |  |
| cn-override-checks.sh | 619 | static-function-array-bad.ast | ast | 8 | en (directive) |  |
| cn-override-checks.sh | 637 | static-function-array-bad-store.ast | ast | 11 | en (directive) |  |
| cn-override-checks.sh | 658 | instance-function-array-en.ast | ast | 15 | en (directive) |  |
| cn-override-checks.sh | 675 | instance-function-array-zh.ast | ast | 19 | zh (directive) |  |
| cn-override-checks.sh | 711 | static-string-array-en.ast | ast | 14 | en (directive) |  |
| cn-override-checks.sh | 741 | static-string-array-zh.ast | ast | 18 | zh (directive) |  |
| cn-override-checks.sh | 775 | object-static-field.ast | ast | 7 | en (directive) |  |
| cn-override-checks.sh | 791 | class-instance-field.ast | ast | 3 | en (directive) |  |
| cn-override-checks.sh | 803 | object-static-array.ast | ast | 7 | en (directive) |  |
| cn-override-checks.sh | 820 | bad-signature.ast | ast | 7 | en (directive) |  |
| cn-override-checks.sh | 836 | missing-annotation.ast | ast | 4 | en (directive) |  |
| cn-override-checks.sh | 849 | no-parent-method.ast | ast | 10 | zh (directive) |  |
| cn-override-checks.sh | 868 | static-override.ast | ast | 11 | en (directive) |  |
| cn-class-checks.sh | 35 | counter-zh.ast | ast | 12 | zh (directive) |  |
| cn-class-checks.sh | 60 | counter-en.ast | ast | 12 | en (directive) |  |
| cn-class-checks.sh | 84 | iface-missing.ast | ast | 10 | zh (directive) |  |
| cn-class-checks.sh | 107 | b26/aster.proj | proj | 6 | - |  |
| cn-class-checks.sh | 115 | b26/src/std.ast | ast | 4 | en (directive) |  |
| cn-class-checks.sh | 121 | b26/src/widget.ast | ast | 8 | en (directive) |  |
| cn-class-checks.sh | 131 | b26/src/main.ast | ast | 5 | en (directive) |  |
| cn-class-checks.sh | 180 | b26-mismatch/src/std.ast | ast | 4 | en (directive) |  |
| cn-class-checks.sh | 214 | b26rt/src/widget.ast | ast | 11 | en (directive) |  |
| cn-class-checks.sh | 227 | b26rt/src/main.ast | ast | 5 | en (directive) |  |
| cn-closure-checks.sh | 27 | closure-capture-zh.ast | ast | 8 | zh (directive) |  |
| cn-closure-checks.sh | 48 | closure-zero-en.ast | ast | 7 | en (directive) |  |
| cn-closure-checks.sh | 67 | closure-unknown-capture.ast | ast | 7 | en (directive) |  |
| cn-embed-checks.sh | 85 | parse-zh.ast | ast | 8 | zh (directive) |  |
| cn-embed-checks.sh | 95 | parse-en.ast | ast | 8 | en (directive) |  |
| cn-embed-checks.sh | 114 | parse-foo.ast | ast | 4 | en (directive) |  |
| cn-embed-checks.sh | 122 | parse-bad.ast | ast | 4 | en (directive) |  |
| cn-embed-checks.sh | 138 | probe.ast | ast | 12 | zh (directive) |  |
| cn-embed-checks.sh | 153 | probe__2.ast | ast | 12 | en (directive) |  |
| cn-embed-checks.sh | 180 | dedup.ast | ast | 11 | en (directive) |  |
| cn-embed-checks.sh | 203 | align.ast | ast | 10 | en (directive) |  |
| cn-embed-checks.sh | 222 | align-max.ast | ast | 10 | en (directive) |  |
| cn-embed-checks.sh | 240 | align-bad3.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 249 | align-bad8192.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 258 | align-len.ast | ast | 4 | en (directive) |  |
| cn-embed-checks.sh | 269 | err-missing.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 279 | err-empty.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 289 | err-dir.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 298 | err-num.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 313 | import/sub/helper.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 320 | import/main.ast | ast | 5 | en (directive) |  |
| cn-embed-checks.sh | 343 | cache/src/main.ast | ast | 6 | en? |  |
| cn-embed-checks.sh | 351 | cache/src/data.ast | ast | 7 | en? |  |
| cn-embed-checks.sh | 386 | multi.ast | ast | 16 | en (directive) |  |
| cn-apk-checks.sh | 62 | p9exe/src/main.ast | ast | 4 | en? |  |
| cn-apk-checks.sh | 68 | p9exe/src/util.ast | ast | 3 | en? |  |
| cn-apk-checks.sh | 86 | p9exe/src/main__2.ast | ast | 6 | en? |  |
| cn-apk-checks.sh | 108 | src/counter.ast | ast | 5 | zh? |  |
| cn-apk-checks.sh | 115 | src/main.ast | ast | 3 | zh? |  |
| cn-apk-checks.sh | 123 | src/counter__2.ast | ast | 5 | en? |  |
| cn-apk-checks.sh | 130 | src/main__2.ast | ast | 4 | en? |  |
| cn-apk-checks.sh | 207 | probe.c | SKIPPED | 8 | - | skipped: expected-output / C probe / $ template |
| cn-diag-checks.sh | 17 | block-zh.ast | ast | 4 | zh (directive) |  |
| cn-diag-checks.sh | 23 | block-en.ast | ast | 3 | en (directive) |  |
| cn-diag-checks.sh | 52 | type-zh.ast | ast | 5 | zh (directive) |  |
| cn-diag-checks.sh | 59 | type-en.ast | ast | 5 | en (directive) |  |
| cn-diag-checks.sh | 89 | bad-language.ast | ast | 2 | en? |  |
| cn-diag-checks.sh | 103 | garbage-en.ast | ast | 2 | en (directive) |  |
| cn-diag-checks.sh | 117 | dup-package-zh.ast | ast | 5 | zh (directive) |  |
| cn-diag-checks.sh | 135 | bad-annotation-en.ast | ast | 3 | en (directive) |  |
| cn-diag-checks.sh | 150 | dup-struct-zh.ast | ast | 10 | zh (directive) |  |
| cn-diag-checks.sh | 172 | hidden-zh.ast | ast | 11 | zh (directive) |  |
| cn-diag-checks.sh | 185 | hidden-en.ast | ast | 9 | en (directive) |  |
| cn-diag-checks.sh | 209 | range-zh.ast | ast | 8 | zh (directive) |  |
| cn-diag-checks.sh | 230 | unterminated-zh.ast | ast | 5 | zh (directive) |  |
| cn-format-checks.sh | 12 | zh.ast | ast | 17 | zh (directive) |  |
| cn-format-checks.sh | 31 | zh.expected | SKIPPED | 17 | - | skipped: expected-output / C probe / $ template |
| cn-format-checks.sh | 67 | en.ast | ast | 9 | en (directive) |  |
| cn-format-checks.sh | 78 | en.expected | SKIPPED | 9 | - | skipped: expected-output / C probe / $ template |
| cn-runtime-checks.sh | 10 | app/string-zh.ast | ast | 12 | zh (directive) |  |
| cn-runtime-checks.sh | 25 | app/string-en.ast | ast | 12 | en (directive) |  |
| cn-sema-checks.sh | 16 | const-write.ast | ast | 6 | zh (directive) |  |
| cn-sema-checks.sh | 34 | unknown-var.ast | ast | 4 | en (directive) |  |
| cn-sema-checks.sh | 50 | count-modify.ast | ast | 8 | zh (directive) |  |
| cn-sema-checks.sh | 70 | zero-step.ast | ast | 7 | zh (directive) |  |
| cn-types-checks.sh | 17 | str-to-ptr.ast | ast | 6 | zh (directive) |  |
| cn-types-checks.sh | 39 | narrow-overflow.ast | ast | 5 | en (directive) |  |
| cn-types-checks.sh | 56 | void-local.ast | ast | 5 | en (directive) |  |
| cn-types-checks.sh | 73 | string-view.ast | ast | 5 | zh (directive) |  |
| cn-traditional-surface-checks.sh | 61 | pointers.ast | ast | 11 | en (directive) |  |
| cn-traditional-surface-checks.sh | 77 | operators.ast | ast | 12 | en (directive) |  |
| cn-traditional-surface-checks.sh | 95 | sizeof.ast | ast | 3 | en (directive) |  |
| cn-traditional-surface-checks.sh | 103 | indirect.ast | ast | 10 | en (directive) |  |
| cn-traditional-surface-checks.sh | 119 | cn-prefix.ast | ast | 3 | en (directive) |  |
| cn-traditional-surface-checks.sh | 125 | reserved-prefix.ast | ast | 3 | en (directive) |  |
| decl-layout-checks.sh | 100 | app-zh.ast | ast | 24 | zh? |  |
| decl-layout-checks.sh | 164 | app-only-zh.ast | ast | 10 | zh? |  |
| decl-layout-checks.sh | 176 | app-only-en.ast | ast | 10 | en? |  |
| decl-layout-checks.sh | 203 | stub-counter-zh.ast | ast | 144 | zh? |  |
| decl-layout-checks.sh | 355 | stub-counter-en.ast | ast | 144 | en? |  |
| decl-layout-checks.sh | 507 | stub-tab-zh.ast | ast | 277 | zh? |  |
| decl-layout-checks.sh | 792 | stub-tab-en.ast | ast | 277 | en? |  |
| decl-layout-checks.sh | 1109 | p21stub.ast | ast | 36 | zh? |  |
| decl-layout-checks.sh | 1299 | p43stub.ast | ast | 40 | zh? |  |
| decl-layout-checks.sh | 1396 | p52.ast | ast | 63 | zh? |  |
| decl-layout-checks.sh | 1646 | w8.ast | ast | 37 | zh? |  |
| decl-layout-checks.sh | 1689 | w3wrap.ast | ast | 41 | zh? |  |
| decl-layout-checks.sh | 1739 | app-en.ast | ast | 24 | en? |  |

## Appendix A — D-2a drafts (`d2a/`)

Copies of `~/workspace/asterui-cn-s1s2/prototypes/d2a/` (read-only source,
UI-side reference repo, not edited): `counter-zh.ast` / `counter-en.ast`
(58 lines each), `tab-input-zh.ast` / `tab-input-en.ast` (102 lines each).
No `// aster:language=` directive in the drafts; language comes from the
`--language` flag (the coverage script runs both, see header). Concatenated
with the decl-layout stubs (extracted above) exactly as
`tests/decl-layout-checks.sh` does (`cat stub <draft>`):

| file | lines | make-up |
|---|---|---|
| `full-counter-zh.ast` / `full-counter-en.ast` | 202 | stub-counter (144) + counter draft (58) |
| `full-tab-zh.ast` / `full-tab-en.ast` | 379 | stub-tab (277) + tab-input draft (102) |
| `min-counter-zh.ast` / `min-counter-en.ast` | 68 | app-only (10) + counter draft (58) |
| `min-tab-zh.ast` / `min-tab-en.ast` | 112 | app-only (10) + tab-input draft (102) |

## Appendix B — Gallery + framework (`gallery/`)

Copies from the UI tree `~/workspace/projects/AsterUI-cn-s1s2/` (read-only
source, not edited), relative layout preserved so the `aster.proj`
`../../src/...` / `../../../src/...` references keep resolving:

| file | lines | source |
|---|---|---|
| `src/aui_impl.ast` | 25,535 | UI tree `src/aui_impl.ast` (25,535-line version, NOT the 24,882-line old copy in this tree's `stdlib/asterui/`) |
| `src/aui.ast` | 1,157 | UI tree `src/aui.ast` |
| `src/aster_std.ast` | 1,728 | UI tree `src/aster_std.ast` (different source from this tree's `stdlib/aster_std.ast`, 1,854 lines) |
| `src/font_runtime.ast` | 577 | UI tree `src/font_runtime.ast` |
| `src/render/truetype.ast` | 4,228 | UI tree `src/render/truetype.ast` |
| `src/render/text.ast` | 437 | UI tree `src/render/text.ast` |
| `assets/embeds.ast` | 64 | UI tree `assets/embeds.ast` |
| `tests/fake_ndk.ast` | — | UI tree `tests/fake_ndk.ast` |
| `examples/gallery-zh/`, `examples/gallery-en/` | app 335 + headless 536/471 | UI tree `examples/gallery-zh/`, `examples/gallery-en/` (`aster.proj`, `src/*.ast`, `tests/headless.ast`; `build/` outputs not copied) |
| `examples/templates/gallery-zh/`, `examples/templates/gallery-en/` | app 320/279 + headless 52/42 | UI tree `examples/templates/gallery-zh/`, `examples/templates/gallery-en/` (same subset) |

## Appendix C — project fix-ups (hand-assembled, sources noted)

- `cn-class/b26-mismatch/`: `aster.proj` + `src/widget.ast` + `src/main.ast`
  copied from `cn-class/b26/` (the suite does the same `cp`); only
  `src/std.ast` is a heredoc extract (mismatched `alloc -> i32`).
- `cn-class/b26rt/`: `aster.proj` copied from `cn-class/b26/`; `src/std.ast`
  is a copy of this tree's `stdlib/aster_std.ast` (the suite copies
  `$ROOT/stdlib/aster_std.ast`); `src/widget.ast` / `src/main.ast` are
  heredoc extracts.
- `cn-apk/p9exe/aster.proj`: `printf` content from `cn-apk-checks.sh`
  (`kind exe`, `[language] default = "en"`, `src/main.ast`, `src/util.ast`).
- `cn-apk/zhcounter/`, `cn-apk/encounter/`: `aster.proj` from the suite's
  `build_counter` `printf` (zh: `kind apk`, `package com.example.zhcounter`,
  `label 计数器`, no `[language]` → default zh; en: `kind apk`,
  `package com.example.encounter`, `label Counter`,
  `[language] default = "en"`); `src/counter.ast` / `src/main.ast` are the
  zh / en heredoc extracts (`counter__2.ast` / `main__2.ast` are the en ones).
- Data files: `cn-embed/data.bin` = bytes `A \x01 \x02 \x03 \x04`
  (the suite's `printf 'A\\001\\002\\003\\004'`);
  `cn-embed/import/sub/helper.bin` = byte `Z` (the suite's `printf 'Z'`).
