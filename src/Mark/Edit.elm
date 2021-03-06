module Mark.Edit exposing
    ( update, Edit, Error
    , Selection, Offset
    , deleteText, insertText
    , Styles, restyle, addStyles, removeStyles
    , annotate, verbatim, verbatimWith
    , replace, delete, insertAt
    )

{-| This module allows you to make **edits** to `Parsed`, that intermediate data structure we talked about in [`Mark`](Mark).

This means you can build an editor for your document.

In order to make edits to your document you need an [`Id`](#Id) and an [`Edit`](#Edit).

Once you have those you can [`update`](#update) your document, which can succeed or fail depending on if the edit was valid.


# Updating `Parsed`

@docs update, Edit, Error


# Text Edits

@docs Selection, Offset

@docs deleteText, insertText

@docs Styles, restyle, addStyles, removeStyles

@docs annotate, verbatim, verbatimWith


# General Edits

@docs replace, delete, insertAt

-}

import Mark.Internal.Description as Desc exposing (..)
import Mark.Internal.Error as Error
import Mark.Internal.Format as Format
import Mark.Internal.Id as Id exposing (..)
import Mark.Internal.Index as Index
import Mark.Internal.Outcome as Outcome
import Mark.Internal.Parser as Parse
import Mark.New
import Parser.Advanced as Parser exposing ((|.), (|=), Parser)


{-| -}
type alias Error =
    Error.Rendered


{-| -}
type alias Id =
    Id.Id


{-| -}
type alias Position =
    { offset : Int
    , line : Int
    , column : Int
    }


{-| -}
type alias Range =
    { start : Position
    , end : Position
    }


{-| -}
type Proved
    = Proved Id (List (Found Description))


{-| -}
type Edit
    = Replace Id Mark.New.Block
      -- Create an element in a ManyOf
      -- Indexes overflow, so if it's too large, it just puts it at the end.
      -- Indexes that are below 0 and clamped to 0
    | InsertAt Id Int Mark.New.Block
    | Delete Id Int
      -- Text Editing
    | StyleText Id Selection Restyle
    | Annotate Id Selection Annotation
    | ReplaceSelection Id Selection (List Mark.New.Text)


type Annotation
    = Annotation String (List ( String, Mark.New.Block ))
    | Verbatim String (List ( String, Mark.New.Block ))


{-| -}
deleteText : Id -> Int -> Int -> Edit
deleteText id anchor focus =
    ReplaceSelection id
        { anchor = anchor
        , focus = focus
        }
        []


{-| -}
insertText : Id -> Int -> List Mark.New.Text -> Edit
insertText id at els =
    ReplaceSelection id { anchor = at, focus = at } els


{-| -}
replace : Id -> Mark.New.Block -> Edit
replace =
    Replace


{-| -}
delete : Id -> Int -> Edit
delete =
    Delete


{-| -}
insertAt : Id -> Int -> Mark.New.Block -> Edit
insertAt =
    InsertAt


{-| -}
annotate : Id -> Selection -> String -> List ( String, Mark.New.Block ) -> Edit
annotate id selection name attrs =
    Annotate id selection (Annotation name attrs)


{-| -}
verbatim : Id -> Selection -> String -> Edit
verbatim id selection name =
    Annotate id selection (Verbatim name [])


{-| -}
verbatimWith : Id -> Selection -> String -> List ( String, Mark.New.Block ) -> Edit
verbatimWith id selection name attrs =
    Annotate id selection (Verbatim name attrs)


{-| -}
restyle : Id -> Selection -> Styles -> Edit
restyle id selection styles =
    StyleText id selection (Restyle styles)


{-| -}
removeStyles : Id -> Selection -> Styles -> Edit
removeStyles id selection styles =
    StyleText id selection (RemoveStyle styles)


{-| -}
addStyles : Id -> Selection -> Styles -> Edit
addStyles id selection styles =
    StyleText id selection (AddStyle styles)


prepareResults doc original ( edited, newDescription ) =
    case edited of
        NoEditMade ->
            Err [ Error.idNotFound ]

        YesEditMade _ ->
            let
                newParsed =
                    Parsed { original | found = newDescription }
            in
            case Desc.render doc newParsed of
                Outcome.Success _ ->
                    Ok newParsed

                Outcome.Almost details ->
                    Err details.errors

                Outcome.Failure errs ->
                    Err errs


editAtId id fn indentation pos desc =
    if Desc.getId desc == id then
        fn indentation pos desc

    else
        Nothing


replaceOption id new desc =
    case desc of
        OneOf one ->
            -- When we're replacing the OneOf, we actually want to replace it's contents.
            let
                newSize =
                    getSize new

                existingSize =
                    sizeFromRange (getFoundRange one.child)
            in
            case one.child of
                Found range val ->
                    Just
                        ( minusSize newSize existingSize
                            |> sizeToPush
                        , OneOf { one | child = Found range new }
                        )

                Unexpected unexpected ->
                    Just
                        ( minusSize newSize existingSize
                            |> sizeToPush
                        , OneOf { one | child = Found unexpected.range new }
                        )

        _ ->
            let
                newSize =
                    getSize new

                existingSize =
                    getSize desc
            in
            Just
                ( minusSize newSize existingSize
                    |> sizeToPush
                , new
                )


sizeToPush size =
    if size.offset == 0 && size.line == 0 then
        Nothing

    else
        Just size


makeDeleteBlock id index indentation pos desc =
    case desc of
        ManyOf many ->
            let
                cleaned =
                    removeByIndex index many.children
            in
            Just
                ( cleaned.push
                , ManyOf
                    { many
                        | children = List.reverse cleaned.items
                    }
                )

        _ ->
            Nothing


{-| -}
update : Document data -> Edit -> Parsed -> Result (List Error) Parsed
update doc edit (Parsed original) =
    let
        editFn =
            case edit of
                Replace id new ->
                    editAtId id <|
                        \i pos desc ->
                            let
                                created =
                                    create
                                        { indent = i
                                        , base = pos
                                        , expectation = new
                                        , seed = original.currentSeed
                                        }
                            in
                            replaceOption id created.desc desc

                InsertAt id index expectation ->
                    editAtId id <|
                        \indentation pos desc ->
                            case desc of
                                ManyOf many ->
                                    let
                                        ( pushed, newChildren ) =
                                            makeInsertAt
                                                original.currentSeed
                                                index
                                                indentation
                                                many
                                                expectation
                                    in
                                    Just
                                        ( pushed
                                        , ManyOf
                                            { many
                                                | children =
                                                    newChildren
                                            }
                                        )

                                _ ->
                                    -- inserts only work for
                                    -- `ManyOf`, `Tree`, and `Text`
                                    Nothing

                Delete id index ->
                    editAtId id
                        (makeDeleteBlock id index)

                StyleText id selection restyleAction ->
                    editAtId id
                        (\indent pos desc ->
                            case desc of
                                DescribeText details ->
                                    let
                                        newTexts =
                                            details.text
                                                |> List.foldl
                                                    (doTextEdit selection
                                                        (List.map (applyStyles restyleAction))
                                                    )
                                                    emptySelectionEdit
                                                |> .elements
                                                |> List.foldl mergeStyles []
                                    in
                                    Just
                                        ( Just (pushNewTexts details.text newTexts)
                                        , DescribeText
                                            { details | text = newTexts }
                                        )

                                _ ->
                                    Nothing
                        )

                Annotate id selection wrapper ->
                    editAtId id
                        (\indent pos desc ->
                            case desc of
                                DescribeText details ->
                                    let
                                        newTexts =
                                            details.text
                                                |> List.foldl
                                                    (doTextEdit selection
                                                        (\els ->
                                                            let
                                                                textStart =
                                                                    getTextStart els
                                                                        |> Maybe.withDefault pos

                                                                wrapped =
                                                                    case wrapper of
                                                                        Annotation name attrs ->
                                                                            ExpectInlineBlock
                                                                                { name = name
                                                                                , kind =
                                                                                    SelectText
                                                                                        (List.concatMap onlyText els)
                                                                                , fields = attrs
                                                                                }

                                                                        Verbatim name attrs ->
                                                                            ExpectInlineBlock
                                                                                { name = name
                                                                                , kind =
                                                                                    SelectString
                                                                                        (List.concatMap onlyText els
                                                                                            |> List.map textString
                                                                                            |> String.join ""
                                                                                        )
                                                                                , fields = attrs
                                                                                }

                                                                ( end, newText ) =
                                                                    createInline
                                                                        textStart
                                                                        [ wrapped ]
                                                            in
                                                            newText
                                                        )
                                                    )
                                                    emptySelectionEdit
                                                |> .elements
                                                |> List.foldl mergeStyles []
                                    in
                                    Just
                                        ( Just (pushNewTexts details.text newTexts)
                                        , DescribeText
                                            { details | text = newTexts }
                                        )

                                _ ->
                                    Nothing
                        )

                ReplaceSelection id selection newTextEls ->
                    editAtId id
                        (\indent pos desc ->
                            case desc of
                                DescribeText details ->
                                    let
                                        makeNewText selectedEls =
                                            newTextEls
                                                |> createInline (Maybe.withDefault pos (getTextStart selectedEls))
                                                |> Tuple.second

                                        newTexts =
                                            details.text
                                                |> List.foldl
                                                    (doTextEdit selection
                                                        makeNewText
                                                    )
                                                    emptySelectionEdit
                                                |> .elements
                                                |> List.foldl mergeStyles []
                                    in
                                    Just
                                        ( Just (pushNewTexts details.text newTexts)
                                        , DescribeText
                                            { details | text = newTexts }
                                        )

                                _ ->
                                    Nothing
                        )
    in
    original.found
        |> makeFoundEdit
            { makeEdit = editFn
            , indentation = 0
            }
        |> prepareResults doc original


pushNewTexts existing new =
    minusSize
        (textSize new)
        (textSize existing)


getTextStart els =
    case els of
        [] ->
            Nothing

        starter :: _ ->
            Just (.start (textDescriptionRange starter))


textString (Text _ str) =
    str


{-| -}
prove : List (Found Description) -> List ( Id, Expectation ) -> Maybe Proved
prove found choices =
    let
        combineChoices ( id, exp ) ( lastId, foundExpectations, matchingIds ) =
            case lastId of
                Nothing ->
                    ( Just id, exp :: foundExpectations, matchingIds )

                Just prev ->
                    if prev == id then
                        ( lastId, exp :: foundExpectations, matchingIds )

                    else
                        ( lastId, foundExpectations, False )

        ( maybeId, expectations, allMatching ) =
            List.foldl combineChoices ( Nothing, [], True ) choices
    in
    if allMatching then
        case maybeId of
            Just id ->
                List.foldl (validate expectations) (Just []) found
                    |> Maybe.map (Proved id << List.reverse)

            Nothing ->
                Nothing

    else
        Nothing


{-| -}
validate : List Expectation -> Found Description -> Maybe (List (Found Description)) -> Maybe (List (Found Description))
validate expectations found validated =
    case validated of
        Nothing ->
            Nothing

        Just vals ->
            case found of
                Found _ description ->
                    if List.any (match description) expectations then
                        Just (found :: vals)

                    else
                        Nothing

                Unexpected unexpected ->
                    Nothing


match description exp =
    case description of
        DescribeBlock details ->
            case exp of
                ExpectBlock expectedName expectedChild ->
                    if expectedName == details.name then
                        matchExpected details.expected expectedChild

                    else
                        False

                _ ->
                    False

        Record details ->
            matchExpected details.expected exp

        OneOf one ->
            matchExpected (ExpectOneOf one.choices) exp

        ManyOf many ->
            matchExpected (ExpectManyOf many.choices) exp

        StartsWith details ->
            case exp of
                ExpectStartsWith startExp endExp ->
                    match details.first.found startExp
                        && match details.second.found endExp

                _ ->
                    False

        DescribeTree myTree ->
            matchExpected myTree.expected exp

        DescribeBoolean foundBoolean ->
            case exp of
                ExpectBoolean _ ->
                    True

                _ ->
                    False

        DescribeInteger _ ->
            case exp of
                ExpectInteger _ ->
                    True

                _ ->
                    False

        DescribeFloat _ ->
            case exp of
                ExpectFloat _ ->
                    True

                _ ->
                    False

        DescribeText _ ->
            case exp of
                ExpectTextBlock _ ->
                    True

                _ ->
                    False

        DescribeString _ _ _ ->
            case exp of
                ExpectString _ ->
                    True

                _ ->
                    False

        DescribeMultiline _ _ _ ->
            case exp of
                ExpectMultiline _ ->
                    True

                _ ->
                    False

        DescribeNothing _ ->
            False


{-| Is the first expectation a subset of the second?
-}
matchExpected : Expectation -> Expectation -> Bool
matchExpected subExp expected =
    case ( subExp, expected ) of
        ( ExpectBlock oneName oneExp, ExpectBlock twoName twoExp ) ->
            oneName == twoName && matchExpected oneExp twoExp

        ( ExpectRecord one oneFields, ExpectRecord two twoFields ) ->
            one == two && List.all (matchFields twoFields) oneFields

        ( ExpectOneOf oneOptions, ExpectOneOf twoOptions ) ->
            List.all (matchExpectedOptions twoOptions) oneOptions

        ( ExpectManyOf oneOptions, ExpectManyOf twoOptions ) ->
            List.all (matchExpectedOptions twoOptions) oneOptions

        ( ExpectStartsWith oneStart oneRemain, ExpectStartsWith twoStart twoRemain ) ->
            matchExpected oneStart twoStart
                && matchExpected oneRemain twoRemain

        ( ExpectBoolean _, ExpectBoolean _ ) ->
            True

        ( ExpectInteger _, ExpectInteger _ ) ->
            True

        ( ExpectFloat _, ExpectFloat _ ) ->
            True

        ( ExpectTextBlock oneInline, ExpectTextBlock twoInline ) ->
            True

        ( ExpectString _, ExpectString _ ) ->
            True

        ( ExpectMultiline _, ExpectMultiline _ ) ->
            True

        ( ExpectTree oneContent _, ExpectTree twoContent _ ) ->
            True

        _ ->
            False


matchExpectedOptions : List Expectation -> Expectation -> Bool
matchExpectedOptions opts target =
    List.any (matchExpected target) opts


matchFields : List ( String, Expectation ) -> ( String, Expectation ) -> Bool
matchFields valid ( targetFieldName, targetFieldExpectation ) =
    let
        innerMatch ( validFieldName, validExpectation ) =
            validFieldName
                == targetFieldName
                && matchExpected validExpectation targetFieldExpectation
    in
    List.any innerMatch valid


type alias EditCursor =
    -- An edit takes the indentation level
    -- , the last reference position
    -- and the current description
    { makeEdit : Int -> Position -> Description -> Maybe ( Push, Description )
    , indentation : Int
    }


type alias Push =
    Maybe Size


type alias Size =
    { offset : Int
    , line : Int
    }


type EditMade
    = YesEditMade Push
    | NoEditMade


{-| -}
makeFoundEdit : EditCursor -> Found Description -> ( EditMade, Found Description )
makeFoundEdit cursor foundDesc =
    case foundDesc of
        Found range desc ->
            case cursor.makeEdit cursor.indentation range.start desc of
                Nothing ->
                    makeEdit cursor desc
                        |> Tuple.mapSecond (Found range)

                Just ( maybePush, newDesc ) ->
                    ( YesEditMade maybePush, Found range newDesc )

        Unexpected unexpected ->
            ( NoEditMade, foundDesc )


increaseIndent x =
    { x | indentation = x.indentation + 1 }


{-| -}
makeEdit : EditCursor -> Description -> ( EditMade, Description )
makeEdit cursor desc =
    case desc of
        DescribeBlock details ->
            case cursor.makeEdit cursor.indentation (foundStart details.found) desc of
                Just ( maybePush, newDesc ) ->
                    -- replace current description
                    ( YesEditMade maybePush, newDesc )

                Nothing ->
                    -- dive further
                    makeFoundEdit (increaseIndent cursor) details.found
                        |> (\( editMade, newFound ) ->
                                case editMade of
                                    NoEditMade ->
                                        ( NoEditMade, desc )

                                    YesEditMade maybePush ->
                                        ( YesEditMade maybePush
                                        , DescribeBlock
                                            { details
                                                | found = newFound
                                            }
                                        )
                           )

        Record details ->
            case cursor.makeEdit (cursor.indentation + 1) (foundStart details.found) desc of
                Just ( maybePush, newDesc ) ->
                    -- replace current description
                    ( YesEditMade maybePush, newDesc )

                Nothing ->
                    case details.found of
                        Found rng fields ->
                            let
                                ( fieldsEdited, updatedFields ) =
                                    List.foldl
                                        (\(( fieldName, foundField ) as field) ( editMade, pastFields ) ->
                                            case editMade of
                                                YesEditMade maybePush ->
                                                    ( editMade
                                                    , ( fieldName
                                                      , case maybePush of
                                                            Nothing ->
                                                                foundField

                                                            Just to ->
                                                                pushFound to foundField
                                                      )
                                                        :: pastFields
                                                    )

                                                NoEditMade ->
                                                    case makeFoundEdit (increaseIndent (increaseIndent cursor)) foundField of
                                                        ( NoEditMade, _ ) ->
                                                            ( NoEditMade, field :: pastFields )

                                                        ( YesEditMade maybePush, newField ) ->
                                                            ( YesEditMade maybePush
                                                            , ( fieldName, newField ) :: pastFields
                                                            )
                                        )
                                        ( NoEditMade, [] )
                                        fields
                            in
                            case fieldsEdited of
                                NoEditMade ->
                                    ( NoEditMade, desc )

                                YesEditMade maybePush ->
                                    ( YesEditMade maybePush
                                    , Record
                                        { details
                                            | found =
                                                Found (expandRange maybePush rng)
                                                    (List.reverse updatedFields)
                                        }
                                    )

                        Unexpected unexpected ->
                            ( NoEditMade, desc )

        OneOf details ->
            case cursor.makeEdit cursor.indentation (foundStart details.child) desc of
                Just ( maybePush, newDesc ) ->
                    -- replace current description
                    ( YesEditMade maybePush
                    , newDesc
                    )

                Nothing ->
                    -- dive further
                    makeFoundEdit (increaseIndent cursor) details.child
                        |> (\( editMade, newFound ) ->
                                case editMade of
                                    NoEditMade ->
                                        ( NoEditMade, desc )

                                    YesEditMade maybePush ->
                                        ( YesEditMade maybePush
                                        , OneOf
                                            { details
                                                | child = expandFound maybePush newFound
                                            }
                                        )
                           )

        ManyOf many ->
            case cursor.makeEdit cursor.indentation many.range.start desc of
                Just ( maybePush, newDesc ) ->
                    -- replace current description
                    ( YesEditMade maybePush, newDesc )

                Nothing ->
                    -- dive further
                    let
                        ( childrenEdited, updatedChildren ) =
                            editMany makeFoundEdit push cursor many.children
                    in
                    case childrenEdited of
                        NoEditMade ->
                            ( NoEditMade, desc )

                        YesEditMade maybePush ->
                            ( childrenEdited
                            , ManyOf
                                { many
                                    | children =
                                        updatedChildren
                                    , range =
                                        case maybePush of
                                            Nothing ->
                                                many.range

                                            Just p ->
                                                pushRange p many.range
                                }
                            )

        StartsWith details ->
            let
                ( firstEdited, firstUpdated ) =
                    makeEdit cursor details.first.found
            in
            case firstEdited of
                NoEditMade ->
                    let
                        ( secondEdited, secondUpdated ) =
                            makeEdit cursor details.second.found
                    in
                    case secondEdited of
                        NoEditMade ->
                            ( NoEditMade, desc )

                        YesEditMade maybePush ->
                            ( YesEditMade maybePush
                            , StartsWith
                                { range = details.range
                                , id = details.id
                                , first = details.first
                                , second =
                                    details.second
                                        |> (\snd ->
                                                { snd | found = secondUpdated }
                                           )
                                }
                            )

                YesEditMade maybePush ->
                    ( YesEditMade maybePush
                    , StartsWith
                        { range = details.range
                        , id = details.id
                        , second = details.second
                        , first =
                            details.first
                                |> (\fst ->
                                        { fst | found = firstUpdated }
                                   )
                        }
                    )

        DescribeTree details ->
            let
                ( treeEdited, newChildren ) =
                    editListNested cursor details.children
            in
            case treeEdited of
                NoEditMade ->
                    ( treeEdited, desc )

                YesEditMade maybePush ->
                    ( treeEdited
                    , DescribeTree
                        { details
                            | children = newChildren
                            , range =
                                case maybePush of
                                    Nothing ->
                                        details.range

                                    Just p ->
                                        pushRange p details.range
                        }
                    )

        -- Primitives
        DescribeBoolean details ->
            replacePrimitive cursor (foundStart details.found) desc

        DescribeInteger found ->
            replacePrimitive cursor (foundStart found.found) desc

        DescribeFloat found ->
            replacePrimitive cursor (foundStart found.found) desc

        DescribeText txt ->
            replacePrimitive cursor (.start txt.range) desc

        DescribeString id range str ->
            replacePrimitive cursor range.start desc

        DescribeMultiline id range str ->
            replacePrimitive cursor range.start desc

        DescribeNothing _ ->
            ( NoEditMade, desc )


editNested cursor (Nested nestedDetails) =
    let
        ( contentEdited, newContent ) =
            editMany makeEdit
                (\maybePush desc ->
                    case maybePush of
                        Nothing ->
                            desc

                        Just p ->
                            pushDescription p desc
                )
                cursor
                nestedDetails.content
    in
    editListNested cursor nestedDetails.children


editListNested cursor lsNested =
    let
        indentedCursor =
            increaseIndent cursor
    in
    lsNested
        |> List.foldl
            (\foundChild ( editMade, pastChildren ) ->
                case editMade of
                    YesEditMade maybePush ->
                        ( editMade
                        , pushNested maybePush foundChild :: pastChildren
                        )

                    NoEditMade ->
                        case editNested indentedCursor foundChild of
                            ( NoEditMade, _ ) ->
                                ( NoEditMade, foundChild :: pastChildren )

                            ( YesEditMade maybePush, newChild ) ->
                                ( YesEditMade maybePush
                                , newChild :: pastChildren
                                )
            )
            ( NoEditMade, [] )
        |> Tuple.mapSecond List.reverse


editMany fn pusher cursor manyItems =
    manyItems
        |> List.foldl
            (\node ( editMade, pastChildren ) ->
                case editMade of
                    YesEditMade maybePush ->
                        ( editMade
                        , pusher maybePush node :: pastChildren
                        )

                    NoEditMade ->
                        case fn (increaseIndent (increaseIndent cursor)) node of
                            ( NoEditMade, _ ) ->
                                ( NoEditMade, node :: pastChildren )

                            ( YesEditMade maybePush, newChild ) ->
                                ( YesEditMade maybePush
                                , newChild :: pastChildren
                                )
            )
            ( NoEditMade, [] )
        |> Tuple.mapSecond List.reverse


foundStart found =
    case found of
        Found rng _ ->
            rng.start

        Unexpected unexpected ->
            unexpected.range.start


replacePrimitive cursor startingPos desc =
    case cursor.makeEdit cursor.indentation startingPos desc of
        Just ( maybePush, newDesc ) ->
            -- replace current description
            ( YesEditMade maybePush, newDesc )

        Nothing ->
            ( NoEditMade, desc )


within rangeOne rangeTwo =
    withinOffsetRange { start = rangeOne.start.offset, end = rangeOne.end.offset } rangeTwo


withinOffsetRange offset range =
    range.start.offset <= offset.start && range.end.offset >= offset.end



{- All the above ids are opaque, so we know they can't be spoofed.

       The editing commands all require one of these opaque values to be constructed.

       An id captures:

           1. The coordinates of a specific point
           2. What operations can be performed at that point
           3. A valid payload

       For Replace

           -> Can we accept an Expectation ++ ID Combo?

           -> Means we can't let the dev create their own Description


   Editing Messages are generated by an Editor that we create.

   Or by an editor fragment that we create.

   The expectation would be inflated with built in defaults


-}
{- EDITING

   A general sketch of Edits.

   If a human is sending updates, then likely these will be single character updates or deletions.



   Simple case, the edit is completely within a leaf node

       -> replace leaf node

   More advanced

       -> get smallest containing block
       -> generate source for that block
       -> replace target range with new string
       -> generate parser for that block
            -> Adjusting correctly for offsets
       -> reparse
       -> replace on AST
            -> Adjust node indexes

   Issues:
       -> Seems like a lot of work.

   Individual Edits

       -> addChar
           -> add space
           -> add newline
       -> deleteChar


-}


{-| Given an expectation and a list of choices, verify that the expectation is a valid choice.
-}
make : Expectation -> List ( id, Expectation ) -> Maybe ( id, Expectation )
make expected options =
    List.filterMap
        (\( id, exp ) ->
            if matchExpected expected exp then
                Just ( id, expected )

            else
                Nothing
        )
        options
        |> List.head


boolToString : Bool -> String
boolToString b =
    if b then
        "True"

    else
        "False"


moveColumn : Int -> Position -> Position
moveColumn num pos =
    { offset = pos.offset + num
    , column = pos.column + num
    , line = pos.line
    }


moveNewline : Position -> Position
moveNewline pos =
    { offset = pos.offset + 1
    , column = 1
    , line = pos.line + 1
    }


removeByIndex index list =
    {- We want to remove an item and push subsequent items based on

    -}
    List.foldl
        (\item cursor ->
            if cursor.index == index then
                let
                    range =
                        getFoundRange item

                    pushSize =
                        range
                            |> sizeFromRange
                            -- we want to remove this, so invert the size.
                            |> invertSize
                            |> Just
                in
                { index = cursor.index + 1
                , items = cursor.items

                -- we also want to eliminate all space till the next item,
                -- so we record the end of this item, and wait
                -- till we see the start of the next to add it to the push
                , recordPushGapTillNextItem =
                    Just range.end
                , push =
                    pushSize
                }

            else
                let
                    pushAmount =
                        case cursor.recordPushGapTillNextItem of
                            Nothing ->
                                cursor.push

                            Just previousEnd ->
                                let
                                    range =
                                        getFoundRange item
                                in
                                { start = previousEnd, end = range.start }
                                    |> sizeFromRange
                                    |> invertSize
                                    |> (\additionalSize ->
                                            Maybe.map (addSizes additionalSize) cursor.push
                                       )
                in
                { index = cursor.index + 1
                , items = push pushAmount item :: cursor.items
                , recordPushGapTillNextItem = Nothing
                , push = pushAmount
                }
        )
        { index = 0
        , items = []
        , recordPushGapTillNextItem = Nothing
        , push = Nothing
        }
        list


addSizes one two =
    { line = one.line + two.line
    , offset = one.offset + two.offset
    }


invertSize size =
    { line = -1 * size.line
    , offset = -1 * size.offset
    }


{-| -}
startDocRange : Range
startDocRange =
    { start =
        startingPoint
    , end =
        startingPoint
    }


expandFound : Push -> Found a -> Found a
expandFound maybePush found =
    case found of
        Found rng a ->
            Found
                (expandRange maybePush rng)
                a

        Unexpected unexp ->
            Unexpected
                { unexp | range = expandRange maybePush unexp.range }


{-| -}
expandRange : Push -> Range -> Range
expandRange maybePush range =
    case maybePush of
        Nothing ->
            range

        Just to ->
            { range
                | end =
                    { offset = range.end.offset + to.offset
                    , line = range.end.line + to.line
                    , column = range.end.column
                    }
            }


pushNested : Push -> Nested Description -> Nested Description
pushNested maybePush ((Nested nestedDetails) as nestedDesc) =
    case maybePush of
        Nothing ->
            nestedDesc

        Just to ->
            Nested
                { nestedDetails
                    | content =
                        List.map
                            (pushDescription to)
                            nestedDetails.content
                    , children =
                        List.map
                            (pushNested maybePush)
                            nestedDetails.children
                }


push : Push -> Found Description -> Found Description
push maybePush found =
    case maybePush of
        Nothing ->
            found

        Just to ->
            pushFound to found


pushFound : Size -> Found Description -> Found Description
pushFound to found =
    case found of
        Found range item ->
            Found (pushRange to range) (pushDescription to item)

        Unexpected unexpected ->
            Unexpected { unexpected | range = pushRange to unexpected.range }


pushFoundRange to found =
    case found of
        Found range item ->
            Found (pushRange to range) item

        Unexpected unexpected ->
            Unexpected { unexpected | range = pushRange to unexpected.range }


pushDescription to desc =
    case desc of
        DescribeNothing _ ->
            desc

        DescribeBlock details ->
            DescribeBlock
                { id = details.id
                , name = details.name
                , found = pushFound to details.found
                , expected = details.expected
                }

        Record details ->
            Record
                { id = details.id
                , name = details.name
                , found =
                    details.found
                        |> pushFoundRange to
                        |> mapFound
                            (List.map
                                (\( field, foundField ) ->
                                    ( field, pushFound to foundField )
                                )
                            )
                , expected = details.expected
                }

        OneOf one ->
            OneOf
                { id = one.id
                , choices = one.choices
                , child = pushFound to one.child
                }

        ManyOf many ->
            ManyOf
                { id = many.id
                , range = pushRange to many.range
                , choices = many.choices
                , children = List.map (pushFound to) many.children
                }

        StartsWith details ->
            StartsWith
                { range = pushRange to details.range
                , id = details.id
                , first =
                    { found = pushDescription to details.first.found
                    , expected = details.first.expected
                    }
                , second =
                    { found = pushDescription to details.second.found
                    , expected = details.second.expected
                    }
                }

        DescribeBoolean details ->
            DescribeBoolean
                { details
                    | found = pushFoundRange to details.found
                }

        DescribeInteger details ->
            DescribeInteger
                { details
                    | found = pushFoundRange to details.found
                }

        DescribeFloat details ->
            DescribeFloat
                { details
                    | found = pushFoundRange to details.found
                }

        DescribeText txt ->
            DescribeText
                { txt
                    | range = pushRange to txt.range
                }

        DescribeString id range str ->
            DescribeString id (pushRange to range) str

        DescribeMultiline id range str ->
            DescribeMultiline
                id
                (pushRange to range)
                str

        DescribeTree myTree ->
            DescribeTree
                { myTree
                    | range = pushRange to myTree.range
                    , children =
                        List.map
                            (Desc.mapNested (pushDescription to))
                            myTree.children
                }


pushRange to range =
    { start = pushPosition to range.start
    , end = pushPosition to range.end
    }


pushPosition to pos =
    { offset = pos.offset + to.offset
    , line = pos.line + to.line
    , column = pos.column
    }


addPositions to pos =
    { offset = pos.offset + to.offset
    , line = pos.line + to.line
    , column = pos.column + to.column
    }


addNewline pos =
    { offset = pos.offset + 1
    , line = pos.line + 1
    }


pushFromRange { start, end } =
    { offset = end.offset - start.offset
    , line = end.line - start.line
    , column = end.column - start.column
    }


minusPosition end start =
    { offset = end.offset - start.offset
    , line = end.line - start.line
    , column = end.column - start.column
    }


sizeToRange start delta =
    { start = start
    , end =
        addPositions start delta
    }


makeInsertAt :
    Id.Seed
    -> Int
    -> Int
    ->
        { children : List (Found Description)
        , choices : List Expectation
        , id : Id
        , range : Range
        }
    -> Expectation
    -> ( Push, List (Found Description) )
makeInsertAt seed index indentation many expectation =
    many.children
        |> List.foldl (insertHelper seed index indentation expectation)
            { index = 0
            , position = many.range.start
            , inserted = False
            , list = []
            , push = Nothing
            }
        |> (\found ->
                if found.inserted then
                    ( Maybe.map
                        (\p ->
                            { offset = p.offset
                            , line = p.line
                            }
                        )
                        found.push
                    , List.reverse found.list
                    )

                else
                    let
                        newStart =
                            { offset = found.position.offset + 2
                            , line = found.position.line + 2
                            , column = (indentation * 4) + 1
                            }

                        created =
                            create
                                { indent = indentation
                                , base = newStart
                                , expectation = expectation
                                , seed = seed
                                }
                    in
                    ( Just
                        (sizeFromRange
                            { start = found.position
                            , end = created.pos
                            }
                        )
                    , List.reverse
                        (Found
                            { start = newStart
                            , end = created.pos
                            }
                            created.desc
                            :: found.list
                        )
                    )
           )


insertHelper seed index indentation expectation item found =
    if found.index == index then
        let
            newStart =
                if index == 0 then
                    { offset = found.position.offset
                    , line = found.position.line
                    , column = (indentation * 4) + 1
                    }

                else
                    { offset = found.position.offset + 2
                    , line = found.position.line + 2
                    , column = (indentation * 4) + 1
                    }

            created =
                create
                    { indent = indentation
                    , base = newStart
                    , expectation = expectation
                    , seed = seed
                    }

            newFound =
                Found
                    { start = newStart
                    , end = created.pos
                    }
                    created.desc

            newDescSize =
                minusPosition created.pos newStart
                    -- A block doesn't account for it's own newline,
                    -- so we have to add one here.
                    |> addNewline

            pushAmount =
                Just (addNewline newDescSize)

            pushed =
                push pushAmount item
        in
        { index = found.index + 1
        , inserted = True
        , list =
            pushed
                :: newFound
                :: found.list
        , push = pushAmount
        , position = .end (getFoundRange pushed)
        }

    else
        let
            pushed =
                push found.push item
        in
        { index = found.index + 1
        , inserted = found.inserted
        , list = pushed :: found.list
        , push = found.push
        , position = .end (getFoundRange pushed)
        }


getFoundRange found =
    case found of
        Found rng _ ->
            rng

        Unexpected unexp ->
            unexp.range


updateFoundBool id newBool desc =
    case desc of
        DescribeBoolean details ->
            if details.id == id then
                case details.found of
                    Found boolRng fl ->
                        Just
                            (DescribeBoolean
                                { id = details.id
                                , found =
                                    Found boolRng
                                        newBool
                                }
                            )

                    Unexpected unexpected ->
                        Just
                            (DescribeBoolean
                                { id = details.id
                                , found =
                                    Found unexpected.range
                                        newBool
                                }
                            )

            else
                Nothing

        _ ->
            Nothing


updateFoundFloat id newFloat desc =
    case desc of
        DescribeFloat details ->
            if details.id == id then
                case details.found of
                    Found floatRng fl ->
                        Just
                            (DescribeFloat
                                { id = details.id
                                , found =
                                    Found floatRng
                                        ( String.fromFloat newFloat, newFloat )
                                }
                            )

                    Unexpected unexpected ->
                        Just
                            (DescribeFloat
                                { id = details.id
                                , found =
                                    Found unexpected.range
                                        ( String.fromFloat newFloat, newFloat )
                                }
                            )

            else
                Nothing

        _ ->
            Nothing


updateFoundString id newString desc =
    case desc of
        DescribeString strId range _ ->
            if strId == id then
                Just (DescribeString strId range newString)

            else
                Nothing

        DescribeMultiline strId range _ ->
            if strId == id then
                Just (DescribeMultiline strId range newString)

            else
                Nothing

        _ ->
            Nothing


updateFoundInt id newInt desc =
    case desc of
        DescribeInteger details ->
            if details.id == id then
                case details.found of
                    Found floatRng fl ->
                        Just
                            (DescribeInteger
                                { id = details.id
                                , found =
                                    Found floatRng
                                        newInt
                                }
                            )

                    Unexpected unexpected ->
                        Just
                            (DescribeInteger
                                { id = details.id
                                , found =
                                    Found unexpected.range
                                        newInt
                                }
                            )

            else
                Nothing

        _ ->
            Nothing


{-| -}
getDescription : Parsed -> Found Description
getDescription (Parsed parsed) =
    parsed.found


{-| -}
getDesc : { start : Int, end : Int } -> Parsed -> List Description
getDesc offset (Parsed parsed) =
    getWithinFound offset parsed.found


{-| -}
getWithinFound : { start : Int, end : Int } -> Found Description -> List Description
getWithinFound offset found =
    case found of
        Found range item ->
            if withinOffsetRange offset range then
                if isPrimitive item then
                    [ item ]

                else
                    [ item ]
                        ++ getContainingDescriptions item offset

            else
                []

        Unexpected unexpected ->
            []


withinFoundLeaf offset found =
    case found of
        Found range item ->
            withinOffsetRange offset range

        Unexpected unexpected ->
            withinOffsetRange offset unexpected.range


isPrimitive : Description -> Bool
isPrimitive description =
    case description of
        DescribeBlock _ ->
            False

        Record _ ->
            False

        OneOf _ ->
            False

        ManyOf _ ->
            False

        StartsWith _ ->
            False

        DescribeTree details ->
            False

        -- Primitives
        DescribeBoolean found ->
            True

        DescribeInteger found ->
            True

        DescribeFloat found ->
            True

        DescribeText _ ->
            True

        DescribeString _ _ _ ->
            True

        DescribeMultiline _ _ _ ->
            True

        DescribeNothing _ ->
            True


{-| -}
getContainingDescriptions : Description -> { start : Int, end : Int } -> List Description
getContainingDescriptions description offset =
    case description of
        DescribeNothing _ ->
            []

        DescribeBlock details ->
            getWithinFound offset details.found

        Record details ->
            case details.found of
                Found range fields ->
                    if withinOffsetRange offset range then
                        List.concatMap (getWithinFound offset << Tuple.second) fields

                    else
                        []

                Unexpected unexpected ->
                    if withinOffsetRange offset unexpected.range then
                        []

                    else
                        []

        OneOf one ->
            getWithinFound offset one.child

        ManyOf many ->
            List.concatMap (getWithinFound offset) many.children

        StartsWith details ->
            if withinOffsetRange offset details.range then
                getContainingDescriptions details.first.found offset
                    ++ getContainingDescriptions details.second.found offset

            else
                []

        DescribeTree details ->
            if withinOffsetRange offset details.range then
                List.concatMap (getWithinNested offset) details.children

            else
                []

        -- Primitives
        DescribeBoolean details ->
            if withinFoundLeaf offset details.found then
                [ description ]

            else
                []

        DescribeInteger details ->
            if withinFoundLeaf offset details.found then
                [ description ]

            else
                []

        DescribeFloat details ->
            if withinFoundLeaf offset details.found then
                [ description ]

            else
                []

        DescribeText txt ->
            if withinOffsetRange offset txt.range then
                [ description ]

            else
                []

        DescribeString id range str ->
            if withinOffsetRange offset range then
                [ description ]

            else
                []

        DescribeMultiline id range str ->
            if withinOffsetRange offset range then
                [ description ]

            else
                []


getWithinNested offset (Nested nest) =
    -- case nest.content of
    --     ( desc, items ) ->
    --         getContainingDescriptions desc offset
    List.concatMap
        (\item ->
            getContainingDescriptions item offset
        )
        nest.content



{- EDITING TEXT -}


{-| -}
type alias Replacement =
    Parse.Replacement


{-| -}
type alias Styles =
    { bold : Bool
    , italic : Bool
    , strike : Bool
    }



-- {-|-}
-- at : Int -> Selection
-- at i =
--     { anchor = 1
--     , focus = i
--     }
-- {-|-}
-- between : Int -> Int -> Selection
-- between anchor focus =
--     { anchor = anchor
--     , focus = focus
--     }


{-| -}
type alias Selection =
    { anchor : Offset
    , focus : Offset
    }


{-| -}
type alias Offset =
    Int



{- TEXT EDITING -}


type Restyle
    = Restyle Styles
    | AddStyle Styles
    | RemoveStyle Styles



{- TEXT EDITING HELP -}


onlyText : TextDescription -> List Text
onlyText txt =
    case txt of
        InlineBlock details ->
            case details.kind of
                EmptyAnnotation ->
                    []

                SelectText ts ->
                    ts

                SelectString str ->
                    [ Text emptyStyles str ]

        Styled _ t ->
            [ t ]


{-| Folds over a list of styles and merges them if they're compatible
-}
mergeStyles : TextDescription -> List TextDescription -> List TextDescription
mergeStyles inlineEl gathered =
    case gathered of
        [] ->
            [ inlineEl ]

        prev :: tail ->
            case attemptMerge inlineEl prev of
                Nothing ->
                    inlineEl :: prev :: tail

                Just merged ->
                    merged :: tail


attemptMerge : TextDescription -> TextDescription -> Maybe TextDescription
attemptMerge first second =
    case ( first, second ) of
        ( Styled rngOne (Text stylingOne strOne), Styled rngTwo (Text stylingTwo strTwo) ) ->
            if stylingOne == stylingTwo then
                Just (Styled (mergeRanges rngOne rngTwo) (Text stylingOne (strOne ++ strTwo)))

            else
                Nothing

        ( InlineBlock one, InlineBlock two ) ->
            let
                matchingAttributes foundOne foundTwo =
                    case ( foundOne, foundTwo ) of
                        ( Found _ attr1, Found _ attr2 ) ->
                            List.map Tuple.first attr1
                                == List.map Tuple.first attr2

                        _ ->
                            False

                mergeMatchingRecords r1 r2 newKind =
                    case ( r1, r2 ) of
                        ( Record rec1, Record rec2 ) ->
                            if
                                rec1.name
                                    == rec2.name
                                    && matchingAttributes rec1.found rec2.found
                            then
                                Just
                                    (InlineBlock
                                        { kind = newKind
                                        , range = mergeRanges one.range two.range
                                        , record = one.record
                                        }
                                    )

                            else
                                Nothing

                        _ ->
                            Nothing
            in
            -- Same == same type, same attribute list, same attribute values
            case ( one.kind, two.kind ) of
                ( EmptyAnnotation, EmptyAnnotation ) ->
                    mergeMatchingRecords one.record two.record EmptyAnnotation

                ( SelectText txt1, SelectText txt2 ) ->
                    mergeMatchingRecords one.record two.record (SelectText (txt1 ++ txt2))

                ( SelectString str1, SelectString str2 ) ->
                    mergeMatchingRecords one.record two.record (SelectString (str1 ++ str2))

                _ ->
                    Nothing

        _ ->
            Nothing


mergeRanges one two =
    { start = one.start
    , end = two.end
    }


emptySelectionEdit =
    { offset = 0
    , elements = []
    , selection = Nothing
    }


doTextEdit :
    Selection
    -> (List TextDescription -> List TextDescription)
    -> TextDescription
    ->
        { elements : List TextDescription
        , offset : Int
        , selection : Maybe (List TextDescription)
        }
    ->
        { elements : List TextDescription
        , offset : Int
        , selection : Maybe (List TextDescription)
        }
doTextEdit { anchor, focus } editFn current cursor =
    let
        start =
            min anchor focus

        end =
            max anchor focus

        len =
            length current
    in
    case cursor.selection of
        Nothing ->
            if cursor.offset <= start && cursor.offset + len >= start then
                {- Start Selection -}
                if cursor.offset + len >= end then
                    {- We finish the selection in this element -}
                    let
                        ( before, afterLarge ) =
                            splitAt (start - cursor.offset) current

                        ( selected, after ) =
                            splitAt (end - start) afterLarge
                    in
                    { offset = cursor.offset + len
                    , elements =
                        after :: editFn [ selected ] ++ (before :: cursor.elements)
                    , selection =
                        Nothing
                    }

                else
                    let
                        ( before, after ) =
                            splitAt (start - cursor.offset) current
                    in
                    { offset = cursor.offset + len
                    , elements =
                        before :: cursor.elements
                    , selection =
                        Just [ after ]
                    }

            else
                { offset = cursor.offset + len
                , elements = current :: cursor.elements
                , selection = cursor.selection
                }

        Just selection ->
            if cursor.offset + len >= end then
                let
                    ( before, after ) =
                        splitAt (end - cursor.offset) current

                    fullSelection =
                        before :: selection
                in
                { offset = cursor.offset + len
                , elements =
                    if cursor.offset + len == end then
                        editFn fullSelection ++ cursor.elements

                    else
                        after :: editFn fullSelection ++ cursor.elements
                , selection = Nothing
                }

            else
                { offset = cursor.offset + len
                , elements = cursor.elements
                , selection = Just (current :: selection)
                }


applyStyles : Restyle -> TextDescription -> TextDescription
applyStyles styling inlineEl =
    case inlineEl of
        Styled range txt ->
            Styled range (applyStylesToText styling txt)

        InlineBlock details ->
            case details.kind of
                SelectText txts ->
                    InlineBlock
                        { details
                            | kind = SelectText (List.map (applyStylesToText styling) txts)
                        }

                x ->
                    inlineEl


applyStylesToText styling (Text styles str) =
    case styling of
        Restyle newStyle ->
            Text newStyle str

        RemoveStyle toRemove ->
            Text
                { bold = styles.bold && not toRemove.bold
                , italic = styles.italic && not toRemove.italic
                , strike = styles.strike && not toRemove.strike
                }
                str

        AddStyle toAdd ->
            Text
                { bold = styles.bold || toAdd.bold
                , italic = styles.italic || toAdd.italic
                , strike = styles.strike || toAdd.strike
                }
                str


{-| Splits the current element based on an index.

This function should only be called when the offset is definitely contained within the element provided, not on the edges.

_Reminder_ Indexes are based on the size of the rendered text.

-}
splitAt : Offset -> TextDescription -> ( TextDescription, TextDescription )
splitAt offset inlineEl =
    case inlineEl of
        Styled range txt ->
            let
                ( leftRange, rightRange ) =
                    splitRange offset range

                ( leftText, rightText ) =
                    splitText offset txt
            in
            ( Styled leftRange leftText
            , Styled rightRange rightText
            )

        InlineBlock details ->
            case details.kind of
                EmptyAnnotation ->
                    -- This shoudn't happen because we're expecting the offset
                    -- to be within the range, and a token has a length of 0
                    ( Styled emptyRange (Text emptyStyles "")
                    , InlineBlock details
                    )

                SelectString str ->
                    let
                        ( leftRange, rightRange ) =
                            splitRange offset details.range

                        leftString =
                            String.slice 0 offset str

                        rightString =
                            String.slice offset -1 str
                    in
                    ( InlineBlock
                        { details
                            | range = leftRange
                            , kind = SelectString leftString
                        }
                    , InlineBlock
                        { details
                            | range = rightRange
                            , kind = SelectString rightString
                        }
                    )

                SelectText txts ->
                    let
                        { left, right } =
                            List.foldl (splitTextElements offset)
                                { offset = 0
                                , left = []
                                , right = []
                                }
                                txts

                        splitTextElements off (Text styling txt) cursor =
                            if off >= cursor.offset && off <= cursor.offset + String.length txt then
                                { offset = cursor.offset + String.length txt
                                , left = Text styling (String.left (offset - cursor.offset) txt) :: cursor.left
                                , right = Text styling (String.dropLeft (offset - cursor.offset) txt) :: cursor.right
                                }

                            else if off < cursor.offset then
                                { offset = cursor.offset + String.length txt
                                , left = cursor.left
                                , right = Text styling txt :: cursor.right
                                }

                            else
                                { offset = cursor.offset + String.length txt
                                , left = Text styling txt :: cursor.left
                                , right = cursor.right
                                }

                        ( leftRange, rightRange ) =
                            splitRange offset details.range
                    in
                    ( InlineBlock
                        { details
                            | range = leftRange
                            , kind = SelectText (List.reverse left)
                        }
                    , InlineBlock
                        { details
                            | range = rightRange
                            , kind = SelectText (List.reverse right)
                        }
                    )


splitText offset (Text styling str) =
    ( Text styling (String.left offset str)
    , Text styling (String.dropLeft offset str)
    )


splitRange offset range =
    let
        -- TODO: This stays on the same line
        middle =
            { offset = range.start.offset + offset
            , line = range.start.line
            , column = range.start.column + offset
            }
    in
    ( range
    , range
    )


emptyRange =
    { start =
        { offset = 0
        , line = 1
        , column = 1
        }
    , end =
        { offset = 0
        , line = 1
        , column = 1
        }
    }
