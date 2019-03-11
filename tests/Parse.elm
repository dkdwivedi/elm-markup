module Parse exposing (suite, text)

{-| -}

import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer, int, list, string)
import Mark
import Mark.Internal.Description as Description
import Mark.Internal.Id as Id
import Mark.Internal.Parser
import Parser.Advanced as Parser
import Test exposing (..)


suite =
    describe "Inline parsing"
        [ test "Parse string attribute" <|
            \_ ->
                Expect.equal
                    (Parser.run
                        (Mark.Internal.Parser.attribute (Description.ExpectAttrString "attr"))
                        "attr = My String variable"
                    )
                    (Ok <|
                        Description.AttrString
                            { name = "attr"
                            , range =
                                { end = { column = 26, line = 1, offset = 25 }
                                , start = { column = 1, line = 1, offset = 0 }
                                }
                            , value = " My String variable"
                            }
                    )
        , test "Single string attrs in list" <|
            \_ ->
                Expect.equal
                    (Parser.run
                        (Parser.loop
                            ( [ Description.ExpectAttrString "attr1"
                              ]
                            , []
                            )
                            Mark.Internal.Parser.attributeList
                        )
                        "attr1 = My String variable"
                    )
                    (Ok <|
                        Just <|
                            [ Description.AttrString
                                { name = "attr1"
                                , range =
                                    { end = { column = 27, line = 1, offset = 26 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                                , value = " My String variable"
                                }
                            ]
                    )
        , test "Many string attrs" <|
            \_ ->
                Expect.equal
                    (Parser.run
                        (Parser.loop
                            ( [ Description.ExpectAttrString "attr1"
                              , Description.ExpectAttrString "attr2"
                              ]
                            , []
                            )
                            Mark.Internal.Parser.attributeList
                        )
                        "attr1 = My String variable, attr2 = My Second variable"
                    )
                    (Ok
                        (Just
                            [ Description.AttrString
                                { name = "attr1"
                                , range =
                                    { end =
                                        { column = 27, line = 1, offset = 26 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                                , value = " My String variable"
                                }
                            , Description.AttrString
                                { name = "attr2"
                                , range =
                                    { end =
                                        { column = 55, line = 1, offset = 54 }
                                    , start = { column = 29, line = 1, offset = 28 }
                                    }
                                , value = " My Second variable"
                                }
                            ]
                        )
                    )
        ]


text =
    describe "styled text and inlines"
        [ test "basic" <|
            \_ ->
                Expect.equal
                    (Parser.run
                        (Mark.Internal.Parser.styledText
                            { inlines = []
                            , replacements = []
                            }
                            { column = 1, line = 1, offset = 0 }
                            []
                            []
                        )
                        "Here is my /styled/ *text*."
                    )
                    (Ok
                        (Description.DescribeText
                            { id =
                                Id.Id
                                    { end = { column = 28, line = 1, offset = 27 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                            , text =
                                [ Description.Styled { end = { column = 12, line = 1, offset = 11 }, start = { column = 1, line = 1, offset = 0 } }
                                    (Description.Text [] "Here is my ")
                                , Description.Styled { end = { column = 18, line = 1, offset = 17 }, start = { column = 12, line = 1, offset = 11 } }
                                    (Description.Text [ Description.Italic ] "styled")
                                , Description.Styled { end = { column = 19, line = 1, offset = 18 }, start = { column = 18, line = 1, offset = 17 } }
                                    (Description.Text [] " ")
                                , Description.Styled { end = { column = 23, line = 1, offset = 22 }, start = { column = 19, line = 1, offset = 18 } }
                                    (Description.Text [ Description.Bold ] "text")
                                , Description.Styled { end = { column = 24, line = 1, offset = 23 }, start = { column = 23, line = 1, offset = 22 } }
                                    (Description.Text [] ".")
                                ]
                            }
                        )
                    )
        , test "basic w/ inline token" <|
            \_ ->
                Expect.equal
                    (Parser.run
                        (Mark.Internal.Parser.styledText
                            { inlines =
                                [ Description.ExpectToken "test"
                                    []
                                ]
                            , replacements = []
                            }
                            { column = 1, line = 1, offset = 0 }
                            []
                            []
                        )
                        "Here is my /styled/ *text*.  And a {test}."
                    )
                    (Ok
                        (Description.DescribeText
                            { id =
                                Id.Id
                                    { end = { column = 43, line = 1, offset = 42 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                            , text =
                                [ Description.Styled
                                    { end = { column = 12, line = 1, offset = 11 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                                    (Description.Text [] "Here is my ")
                                , Description.Styled
                                    { end = { column = 18, line = 1, offset = 17 }
                                    , start = { column = 12, line = 1, offset = 11 }
                                    }
                                    (Description.Text [ Description.Italic ] "styled")
                                , Description.Styled
                                    { end = { column = 19, line = 1, offset = 18 }
                                    , start = { column = 18, line = 1, offset = 17 }
                                    }
                                    (Description.Text [] " ")
                                , Description.Styled
                                    { end = { column = 23, line = 1, offset = 22 }
                                    , start = { column = 19, line = 1, offset = 18 }
                                    }
                                    (Description.Text [ Description.Bold ] "text")
                                , Description.Styled
                                    { end = { column = 32, line = 1, offset = 31 }
                                    , start = { column = 23, line = 1, offset = 22 }
                                    }
                                    (Description.Text [] ".  And a ")
                                , Description.InlineToken
                                    { attributes = []
                                    , name = "test"
                                    , range =
                                        { end = { column = 41, line = 1, offset = 40 }
                                        , start = { column = 37, line = 1, offset = 36 }
                                        }
                                    }
                                , Description.Styled
                                    { end = { column = 43, line = 1, offset = 42 }
                                    , start = { column = 42, line = 1, offset = 41 }
                                    }
                                    (Description.Text [] ".")
                                ]
                            }
                        )
                    )
        , test "basic w/ inline token w/ string attr" <|
            \_ ->
                Expect.equal
                    (Parser.run
                        (Mark.Internal.Parser.styledText
                            { inlines =
                                [ Description.ExpectToken "test"
                                    [ Description.ExpectAttrString "attr"
                                    ]
                                ]
                            , replacements = []
                            }
                            { column = 1, line = 1, offset = 0 }
                            []
                            []
                        )
                        "Here is my /styled/ *text*.  And a {test|attr = my string}."
                    )
                    (Ok
                        (Description.DescribeText
                            { id =
                                Id.Id
                                    { end = { column = 60, line = 1, offset = 59 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                            , text =
                                [ Description.Styled
                                    { end = { column = 12, line = 1, offset = 11 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                                    (Description.Text [] "Here is my ")
                                , Description.Styled
                                    { end = { column = 18, line = 1, offset = 17 }
                                    , start = { column = 12, line = 1, offset = 11 }
                                    }
                                    (Description.Text [ Description.Italic ] "styled")
                                , Description.Styled
                                    { end = { column = 19, line = 1, offset = 18 }
                                    , start = { column = 18, line = 1, offset = 17 }
                                    }
                                    (Description.Text [] " ")
                                , Description.Styled
                                    { end = { column = 23, line = 1, offset = 22 }
                                    , start = { column = 19, line = 1, offset = 18 }
                                    }
                                    (Description.Text [ Description.Bold ] "text")
                                , Description.Styled
                                    { end = { column = 32, line = 1, offset = 31 }
                                    , start = { column = 23, line = 1, offset = 22 }
                                    }
                                    (Description.Text [] ".  And a ")
                                , Description.InlineToken
                                    { attributes =
                                        [ Description.AttrString
                                            { name = "attr"
                                            , range =
                                                { end =
                                                    { column = 58
                                                    , line = 1
                                                    , offset = 57
                                                    }
                                                , start = { column = 42, line = 1, offset = 41 }
                                                }
                                            , value = " my string"
                                            }
                                        ]
                                    , name = "test"
                                    , range =
                                        { end = { column = 58, line = 1, offset = 57 }, start = { column = 37, line = 1, offset = 36 } }
                                    }
                                , Description.Styled
                                    { end = { column = 60, line = 1, offset = 59 }
                                    , start = { column = 59, line = 1, offset = 58 }
                                    }
                                    (Description.Text [] ".")
                                ]
                            }
                        )
                    )
        , test "basic w/ inline annotation" <|
            \_ ->
                Expect.equal
                    (Parser.run
                        (Mark.Internal.Parser.styledText
                            { inlines =
                                [ Description.ExpectAnnotation
                                    [ Description.ExpectAttrString "attr"
                                    ]
                                ]
                            , replacements = []
                            }
                            { column = 1, line = 1, offset = 0 }
                            []
                            []
                        )
                        "Here is my /styled/ *text*.  And a [some text]{attr = my string}."
                    )
                    (Ok
                        (Description.DescribeText
                            { id =
                                Id.Id
                                    { end = { column = 60, line = 1, offset = 59 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                            , text =
                                [ Description.Styled
                                    { end = { column = 12, line = 1, offset = 11 }
                                    , start = { column = 1, line = 1, offset = 0 }
                                    }
                                    (Description.Text [] "Here is my ")
                                , Description.Styled
                                    { end = { column = 18, line = 1, offset = 17 }
                                    , start = { column = 12, line = 1, offset = 11 }
                                    }
                                    (Description.Text [ Description.Italic ] "styled")
                                , Description.Styled
                                    { end = { column = 19, line = 1, offset = 18 }
                                    , start = { column = 18, line = 1, offset = 17 }
                                    }
                                    (Description.Text [] " ")
                                , Description.Styled
                                    { end = { column = 23, line = 1, offset = 22 }
                                    , start = { column = 19, line = 1, offset = 18 }
                                    }
                                    (Description.Text [ Description.Bold ] "text")
                                , Description.Styled
                                    { end = { column = 32, line = 1, offset = 31 }
                                    , start = { column = 23, line = 1, offset = 22 }
                                    }
                                    (Description.Text [] ".  And a ")
                                , Description.InlineToken
                                    { attributes =
                                        [ Description.AttrString
                                            { name = "attr"
                                            , range =
                                                { end =
                                                    { column = 58
                                                    , line = 1
                                                    , offset = 57
                                                    }
                                                , start = { column = 42, line = 1, offset = 41 }
                                                }
                                            , value = " my string"
                                            }
                                        ]
                                    , name = "test"
                                    , range =
                                        { end = { column = 58, line = 1, offset = 57 }, start = { column = 37, line = 1, offset = 36 } }
                                    }
                                , Description.Styled
                                    { end = { column = 60, line = 1, offset = 59 }
                                    , start = { column = 59, line = 1, offset = 58 }
                                    }
                                    (Description.Text [] ".")
                                ]
                            }
                        )
                    )
        ]