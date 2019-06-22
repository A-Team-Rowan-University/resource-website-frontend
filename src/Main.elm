port module Main exposing
    ( Model
    , Msg(..)
    , init
    , main
    , subscriptions
    , update
    , view
    )

import Browser
import Browser.Navigation as Nav
import Config exposing (..)
import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput)
import Http exposing (Progress, emptyBody, header, jsonBody)
import Json.Decode as D
import Json.Encode as E
import Network exposing (..)
import Platform.Cmd
import Platform.Sub
import Session exposing (Session, googleUserDecoder, idToken)
import Set exposing (Set)
import Url
import Url.Builder as B
import Url.Parser as P exposing ((</>))
import Users.Detail
import Users.New
import Users.Users as User


main =
    Browser.application
        { init = init
        , subscriptions = subscriptions
        , update = update
        , view = view
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    signIn SignedIn



-- Ports


port signIn : (E.Value -> msg) -> Sub msg



-- MODEL


type Route
    = Home
    | Users
    | UserDetail Int
    | UserNew
    | NotFound


routeParser : P.Parser (Route -> a) a
routeParser =
    P.oneOf
        [ P.map Home P.top
        , P.map Users (P.s "users")
        , P.map UserDetail (P.s "users" </> P.int)
        , P.map UserNew (P.s "users" </> P.s "new")
        ]


type alias Model =
    { navkey : Nav.Key
    , route : Route
    , session : Session User.Id
    , users : Dict User.Id User.User
    , user_detail : Users.Detail.State
    , user_new : Users.New.State
    , requests : Set String
    , notifications : List Notification
    }


handleRequestChanges : List RequestChange -> Set String -> Set String
handleRequestChanges request_changes original_requests =
    List.foldr
        (\request_change requests ->
            case request_change of
                AddRequest r ->
                    Set.insert r requests

                RemoveRequest r ->
                    Set.remove r requests
        )
        original_requests
        request_changes


init : () -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init _ url key =
    ( { navkey = key
      , route = Maybe.withDefault NotFound (P.parse routeParser url)
      , session = Session.NotSignedIn
      , users = Dict.empty
      , user_detail = Users.Detail.init
      , user_new = Users.New.init
      , requests = Set.empty
      , notifications = []
      }
    , Cmd.none
    )



-- UPDATE


type Msg
    = SignedIn E.Value
    | Validated (Result Http.Error User.User)
    | LinkClicked Browser.UrlRequest
    | UrlChanged Url.Url
    | GotUsers (Result Http.Error (List User.User))
    | GotUser User.Id (Result Http.Error User.User)
    | UserDetailMsg Users.Detail.Msg
    | UserNewMsg Users.New.Msg
    | Updated (Result Http.Error ())
    | CloseNotification Int


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SignedIn user_json ->
            case D.decodeValue googleUserDecoder user_json of
                Ok google_user ->
                    ( { model
                        | session = Session.SignedIn google_user
                      }
                    , Http.request
                        { method = "GET"
                        , headers =
                            [ header
                                "id_token"
                                google_user.id_token
                            ]
                        , url =
                            B.relative [ apiUrl, "users", "current" ]
                                []
                        , body = emptyBody
                        , expect = Http.expectJson Validated User.decoder
                        , timeout = Nothing
                        , tracker = Nothing
                        }
                    )

                Err e ->
                    ( { model | session = Session.GoogleError e }
                    , Cmd.none
                    )

        Validated user_result ->
            case model.session of
                Session.SignedIn google_user ->
                    case user_result of
                        Ok user ->
                            let
                                session =
                                    Session.Validated user.id google_user

                                ( cmd, request, notifications ) =
                                    loadData session model.route
                            in
                            ( { model
                                | session = session
                                , users =
                                    Dict.insert
                                        user.id
                                        user
                                        model.users
                                , requests =
                                    handleRequestChanges
                                        request
                                        model.requests
                                , notifications =
                                    model.notifications ++ notifications
                              }
                            , cmd
                            )

                        Err e ->
                            ( { model | session = Session.NetworkError e }
                            , Cmd.none
                            )

                _ ->
                    ( model, Cmd.none )

        GotUsers users_result ->
            ( case users_result of
                Ok users ->
                    { model
                        | users =
                            Dict.fromList
                                (List.map (\u -> ( u.id, u )) users)
                        , requests =
                            handleRequestChanges
                                [ User.manyUrl |> RemoveRequest ]
                                model.requests
                    }

                Err e ->
                    { model
                        | requests =
                            handleRequestChanges
                                [ User.manyUrl |> RemoveRequest ]
                                model.requests
                    }
            , Cmd.none
            )

        GotUser id user_result ->
            ( case user_result of
                Ok user ->
                    { model
                        | users = Dict.insert user.id user model.users
                        , requests =
                            handleRequestChanges
                                [ User.singleUrl id |> RemoveRequest ]
                                model.requests
                    }

                Err e ->
                    { model
                        | requests =
                            handleRequestChanges
                                [ User.singleUrl id |> RemoveRequest ]
                                model.requests
                    }
            , Cmd.none
            )

        UserDetailMsg detail_msg ->
            case ( model.route, idToken model.session ) of
                ( UserDetail id, Just id_token ) ->
                    -- TODO Make this prettier
                    let
                        response =
                            Users.Detail.update
                                id_token
                                model.user_detail
                                detail_msg
                                id

                        ( cmd, requests, notifications ) =
                            if response.reload then
                                let
                                    ( load_cmd, load_request, load_notifications ) =
                                        loadData
                                            model.session
                                            model.route
                                in
                                ( Cmd.batch
                                    [ Cmd.map UserDetailMsg response.cmd
                                    , load_cmd
                                    ]
                                , response.requests ++ load_request
                                , response.notifications
                                    ++ load_notifications
                                )

                            else
                                ( Cmd.map UserDetailMsg response.cmd
                                , response.requests
                                , response.notifications
                                )
                    in
                    ( { model
                        | user_detail = response.state
                        , requests =
                            handleRequestChanges
                                requests
                                model.requests
                        , notifications =
                            model.notifications
                                ++ notifications
                      }
                    , cmd
                    )

                _ ->
                    ( model, Cmd.none )

        UserNewMsg new_msg ->
            case idToken model.session of
                Just id_token ->
                    let
                        response =
                            Users.New.update
                                id_token
                                model.user_new
                                new_msg
                    in
                    ( { model
                        | user_new = response.state
                        , requests =
                            handleRequestChanges
                                response.requests
                                model.requests
                        , notifications =
                            model.notifications
                                ++ response.notifications
                      }
                    , if response.done then
                        Cmd.batch
                            [ response.cmd |> Cmd.map UserNewMsg
                            , Nav.pushUrl model.navkey "/users"
                            ]

                      else
                        response.cmd |> Cmd.map UserNewMsg
                    )

                Nothing ->
                    ( model, Cmd.none )

        Updated _ ->
            let
                ( cmd, request, notifications ) =
                    loadData model.session model.route
            in
            ( { model
                | requests =
                    handleRequestChanges
                        request
                        model.requests
                , notifications =
                    model.notifications ++ notifications
              }
            , cmd
            )

        -- 0 1 2 3 4 5 6
        CloseNotification index ->
            ( { model
                | notifications =
                    List.take index model.notifications
                        ++ List.drop (index + 1) model.notifications
              }
            , Cmd.none
            )

        LinkClicked request ->
            case request of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.navkey (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            case P.parse routeParser url of
                Nothing ->
                    ( { model | route = NotFound }, Cmd.none )

                Just route ->
                    let
                        ( cmd, request, notifications ) =
                            loadData model.session route
                    in
                    ( { model
                        | route = route
                        , requests =
                            handleRequestChanges
                                request
                                model.requests
                        , notifications =
                            model.notifications ++ notifications
                      }
                    , cmd
                    )


loadData :
    Session User.Id
    -> Route
    -> ( Cmd Msg, List RequestChange, List Notification )
loadData session route =
    case route of
        Home ->
            ( Cmd.none, [], [] )

        Users ->
            case idToken session of
                Just id_token ->
                    ( Http.request
                        { method = "GET"
                        , headers = [ header "id_token" id_token ]
                        , url = User.manyUrl
                        , body = emptyBody
                        , expect = Http.expectJson GotUsers User.listDecoder
                        , timeout = Nothing
                        , tracker = User.manyUrl |> Just
                        }
                    , [ User.manyUrl |> AddRequest ]
                    , []
                    )

                Nothing ->
                    ( Cmd.none
                    , []
                    , [ NWarning "You must be logged in to get users" ]
                    )

        UserDetail user_id ->
            case idToken session of
                Just id_token ->
                    let
                        tracker =
                            "get user " ++ String.fromInt user_id
                    in
                    ( Http.request
                        { method = "GET"
                        , headers = [ header "id_token" id_token ]
                        , url = User.singleUrl user_id
                        , body = emptyBody
                        , expect =
                            Http.expectJson
                                (GotUser user_id)
                                User.decoder
                        , timeout = Nothing
                        , tracker = User.singleUrl user_id |> Just
                        }
                    , [ User.singleUrl user_id |> AddRequest ]
                    , []
                    )

                Nothing ->
                    ( Cmd.none
                    , []
                    , [ NWarning "You must be logged in to get users" ]
                    )

        UserNew ->
            ( Cmd.none, [], [] )

        NotFound ->
            ( Cmd.none, [], [] )



-- VIEW
{-
   | NewFirstName String
   | NewLastName String
   | NewBannerId (Maybe Int)
   | NewEmail String
   | EditNewUserAccess (Maybe Int)
   | SubmitNewUserAccess
   | RemoveNewUserAccess Int
   | SubmitNewUser
-}


viewPage : Model -> Html Msg
viewPage model =
    case model.route of
        Users ->
            User.viewList model.users

        UserDetail user_id ->
            case Dict.get user_id model.users of
                Just user ->
                    Users.Detail.view user model.user_detail
                        |> Html.map UserDetailMsg

                Nothing ->
                    p [] [ text "User not found" ]

        UserNew ->
            Users.New.view model.user_new |> Html.map UserNewMsg

        Home ->
            h1 [] [ text "Welcome to the A-Team!" ]

        NotFound ->
            h1 [] [ text "Page not found!" ]


viewSession : Session User.Id -> Dict User.Id User.User -> Html msg
viewSession model users =
    case model of
        Session.Validated user_id google_user ->
            case Dict.get user_id users of
                Just user ->
                    viewValidated user google_user

                Nothing ->
                    div [] [ text "User not found!" ]

        Session.SignedIn google_iser ->
            div [] [ text "Validating..." ]

        Session.NotSignedIn ->
            div []
                [ div []
                    [ div
                        [ class "g-signin2"
                        , attribute "data-onsuccess" "onSignIn"
                        ]
                        [ text "Waiting for Google..." ]
                    ]
                ]

        Session.GoogleError _ ->
            div [] [ text "Google failed to sign in" ]

        Session.NetworkError error ->
            div [] [ text "Network error validating" ]

        Session.AccessDenied ->
            div [] [ text "Access denied!" ]


viewValidated : User.User -> Session.GoogleUser -> Html msg
viewValidated user google_user =
    span [ class "level" ]
        ([ div [ class "level-left" ]
            [ p [ class "has-text-left", class "level-item" ]
                [ text (user.first_name ++ " " ++ user.last_name) ]
            ]
         ]
            |> (\l ->
                    case google_user.image_url of
                        Just image_url ->
                            List.append l
                                [ div [ class "level-right" ]
                                    [ div
                                        [ class "image is-32x32"
                                        , class "level-item"
                                        ]
                                        [ img [ src image_url ] [] ]
                                    ]
                                ]

                        Nothing ->
                            l
               )
        )


view : Model -> Browser.Document Msg
view model =
    { title = "A-Team!"
    , body =
        [ div []
            [ nav [ class "navbar", class "is-primary" ]
                [ div [ class "navbar-brand" ]
                    [ a [ class "navbar-item", href "/" ]
                        [ img
                            [ src
                                (B.relative [ staticUrl, "logo.svg" ] [])
                            ]
                            []
                        ]
                    , a
                        [ attribute "role" "button"
                        , class "navbar-burger"
                        , class "burger"
                        , attribute "aria-label" "menu"
                        , attribute "aria-expanded" "false"
                        , attribute "data-target" "navbar"
                        ]
                        [ span [ attribute "aria-hidden" "true" ] []
                        , span [ attribute "aria-hidden" "true" ] []
                        , span [ attribute "aria-hidden" "true" ] []
                        ]
                    ]
                , div [ id "navbar", class "navbar-menu" ]
                    [ div [ class "navbar-start" ]
                        [ a [ class "navbar-item", href "/" ]
                            [ text "Home" ]
                        , a [ class "navbar-item", href "/users" ]
                            [ text "Users" ]
                        ]
                    , div [ class "navbar-end" ]
                        [ div [ class "navbar-item" ]
                            [ viewSession model.session model.users ]
                        ]
                    ]
                ]
            , div [ class "columns" ]
                [ div [ class "column is-one-fifth" ]
                    (Set.toList model.requests
                        |> List.map (\t -> div [ class "box" ] [ text t ])
                    )
                , div [ class "column" ] [ viewPage model ]
                , div [ class "column is-one-fifth" ]
                    (List.indexedMap (viewNotification CloseNotification) model.notifications)
                ]
            ]
        ]
    }


viewNotification : (Int -> msg) -> Int -> Notification -> Html msg
viewNotification onClose index notification =
    case notification of
        NError t ->
            div [ class "notification is-danger" ]
                [ button [ class "delete", onClick (onClose index) ] []
                , text t
                ]

        NWarning t ->
            div [ class "notification is-warning" ]
                [ button [ class "delete", onClick (onClose index) ] []
                , text t
                ]

        NInfo t ->
            div [ class "notification is-info" ]
                [ button [ class "delete", onClick (onClose index) ] []
                , text t
                ]

        NDebug t ->
            div [ class "notification" ]
                [ button [ class "delete", onClick (onClose index) ] []
                , text t
                ]
