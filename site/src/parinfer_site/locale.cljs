(ns parinfer-site.locale
  "Locale support. It's for Korean for now.
  Hopefully some other languages to be added."
  (:require [om.core :as om :include-macros true]
            [sablono.core :refer-macros [html]]
            [parinfer-site.state :refer [state]]
            [parinfer-site.gears :as gears]))

(def locales [[:en "English"]
              [:ko "한국어"]])

(def gear-captions
  {:ko {"change parens" "괄호 바꾸기"
        "change indentation" "들여쓰기 바꾸기"}})

(defn locale-component
  [{locale :locale} owner]
  (reify
    om/IRender
    (render [_]
      (html
       [:div
        (for [[k v] locales]
          [:span [:a {:href "#" :on-click ""} v]])]))))

(defn text [str]
  (get-in gear-captions [:ko str] str))

(defn init! []
  (om/root
   locale-component
   state
   {:target (js/document.getElementById "locale")}))
