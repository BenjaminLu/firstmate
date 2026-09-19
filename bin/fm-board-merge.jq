# fm-board-merge.jq - refresh the mechanical half of a board payload from live
# fleet state while carrying the written half forward.
#
# bin/fm-board-github.sh owns the contract; this file is the projection it
# runs. A board payload is part mechanical and part written: the fleet rows,
# and a card seeded from a verified packet, come from the snapshot, but a
# decision card's prose is composed by firstmate. A publish triggered by a
# fleet event has the fresh mechanical half and no author, so it takes the
# fresh rows and carries each written card forward by its key.
#
# It will not invent prose. A call that is new since the last board and has no
# verified packet has no words anywhere, so its card is left out and the board
# gains a warning row naming it - the same shape the board already uses for a
# call it cannot address. Firstmate's next build writes it properly.
#
# $fresh is the compose projection of live state; $prev is the last published
# payload, or [] when nothing has been published yet.

def placeholder_re: "\\{(FILL|TRANSLATE)(:[^}]*)?\\}";

# A value is unwritten when any string anywhere inside it is still a composer
# placeholder. Walking the whole card is deliberate: a placeholder buried in an
# option's consequence is as unreadable as one in the title.
def unwritten:
  [.. | strings | select(test(placeholder_re))] | length > 0;

def i18n($en; $hant; $hans): {en: $en, hant: $hant, hans: $hans};

def unwritten_warning:
  . as $card
  | {
      repo: ($card.repo // null),
      id: $card.key,
      kind: "warning",
      dispatchable: false,
      title: i18n(
        "A new call needs writing up: " + $card.key;
        "有一則新的待決事項還沒寫好：" + $card.key;
        "有一则新的待决事项还没写好：" + $card.key),
      reason: i18n(
        "It appeared after the last board was written and has no verified packet, so this store has no words for it. It is named here rather than shown as a card that cannot be read.";
        "它是在上一版看板寫好之後才出現的，也沒有已驗證的決策包，所以這份資料裡沒有它的說明。這裡只先點名，不放一張讀不了的卡。";
        "它是在上一版看板写好之后才出现的，也没有已验证的决策包，所以这份数据里没有它的说明。这里只先点名，不放一张读不了的卡。")
    };

($fresh[0]) as $new
| ($prev[0] // null) as $old
| ($old.captains_call // []) as $carried
| [ $new.captains_call[]
    | . as $card
    | if ($card | unwritten | not) then {keep: $card}
      else
        ( [$carried[] | select(.key == $card.key and (unwritten | not))] | first ) as $prior
        | if $prior then {keep: $prior} else {warn: ($card | unwritten_warning)} end
      end
  ] as $decided
| $new
| .captains_call = [$decided[] | select(has("keep")) | .keep]
| .charted = (($new.charted // []) + [$decided[] | select(has("warn")) | .warn])
