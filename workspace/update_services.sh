
function gup
{
  # subshell for `set -e` and `trap`
  (
    set -e # fail immediately if there's a problem

    # use `git-up` if installed
    if type git-up > /dev/null 2>&1
    then
      exec git-up
    fi

    # fetch upstream changes
    git fetch

    BRANCH=$(git symbolic-ref -q HEAD)
    BRANCH=${BRANCH##refs/heads/}
    BRANCH=${BRANCH:-HEAD}

    if [ -z "$(git config branch.$BRANCH.remote)" -o -z "$(git config branch.$BRANCH.merge)" ]
    then
      echo "\"$BRANCH\" is not a tracking branch." >&2
      exit 1
    fi

    # create a temp file for capturing command output
    TEMPFILE="`mktemp -t gup.XXXXXX`"
    trap '{ rm -f "$TEMPFILE"; }' EXIT

    # if we're behind upstream, we need to update
    if git status | grep "# Your branch" > "$TEMPFILE"
    then

      # extract tracking branch from message
      UPSTREAM=$(cat "$TEMPFILE" | cut -d "'" -f 2)
      if [ -z "$UPSTREAM" ]
      then
        echo Could not detect upstream branch >&2
        exit 1
      fi

      # can we fast-forward?
      CAN_FF=1
      grep -q "can be fast-forwarded" "$TEMPFILE" || CAN_FF=0

      # stash any uncommitted changes
      git stash | tee "$TEMPFILE"
      [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1

      # take note if anything was stashed
      HAVE_STASH=0
      grep -q "No local changes" "$TEMPFILE" || HAVE_STASH=1

      if [ "$CAN_FF" -ne 0 ]
      then
        # if nothing has changed locally, just fast foward.
        git merge --ff "$UPSTREAM"
      else
        # rebase our changes on top of upstream, but keep any merges
        git rebase -p "$UPSTREAM"
      fi

      # restore any stashed changes
      if [ "$HAVE_STASH" -ne 0 ]
      then
        git stash pop
      fi

    fi

  )
}


printf "\n"
echo "Updating turnstile.."
echo "===================="
cd turnstile && git st && gup
cd ../

printf "\n"
echo "Updating customer service.."
echo "============================"
cd customerservice && git st && gup
echo "Updating entry service.."
cd ../ 
cd entry_service && git st && gup
cd ../

printf "\n"
echo "Updating legacy service.."
echo "============================"
cd legacy_service && git st && gup
cd ../

printf "\n"
echo "Updating catalog..."
echo "============================"
cd catalog_service && git st && gup
cd ../

printf "\n"
echo "Updating orders..."
echo "============================"
cd orders_service && git st && gup
cd ../

printf "\n"
echo "Updating comp man"
echo "============================"
cd competition_management && git st && gup
cd ../

printf "\n"
echo "Updating payment service..."
echo "============================"
cd payment_service && git st && gup
cd ../

printf "\n"
echo "Updating communication service..."
echo "============================"
cd communication_service && git st && gup
cd ../

printf "\n"
echo "Updating infra..."
echo "============================"
cd infra && git st && gup
cd ../

printf "\n"
echo "Updating communication service client..."
echo "============================"
cd communication_service_client && git st && gup
cd ../

printf "\n"
echo "Updating payment service client..."
echo "============================"
cd payment_service_client && git st && gup
cd ../

printf "\n"
echo "Updating orders service client..."
echo "============================"
cd orders_service_client && git st && gup
cd ../

printf "\n"
echo "Updating entry service client..."
echo "============================"
cd entry_service_client && git st && gup
cd ../

printf "\n"
echo "Updating competition service client..."
echo "============================"
cd competition_service_client && git st && gup
cd ../

printf "\n"
echo "Updating customer service client..."
echo "============================"
cd customer_service_client && git st && gup
cd ../

printf "\n"
echo "Updating catalog service client.."
echo "============================"
cd catalog_service_client && git st && gup
cd ../

printf "\n"
echo "Updating scheduler.."
echo "============================"
cd scheduler && git st && gup
cd ../
