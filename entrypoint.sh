#!/bin/bash

# check command 
if [[ -z "$(echo 'UPLOAD VALIDATE' | grep -w "$CMD")" ]] ; then
    echo "ERROR: Wrong command received: '$CMD'"
    exit 1
fi

echo ${GITHUB_TOKEN} | gh auth login --with-token
if [ -z $? ] ; then
    echo "Authorizaton error, update AUTOMATION_TOKEN in repo secrets"
    exit 1
fi

if [ ${CMD} == 'UPLOAD' ] ; then
    echo uploading symbol info
    ENVIRONMENT=${GITHUB_REF##*/}
    if [[ -z "$(echo 'production staging' | grep -w "$ENVIRONMENT")" ]] ; then
        echo "ERROR: Wrong environment: '$ENVIRONMENT'. It must be 'production' or 'staging'"
        exit 1
    fi
    INTEGRATION_NAME=${GITHUB_REPOSITORY##*/}
    for F in $(ls symbols);
    do
        FINAL_NAME=${INTEGRATION_NAME}/$(basename "$F")
        echo uploading symbols/$F to $S3_BUCKET_SYMBOLS/$ENVIRONMENT/$FINAL_NAME
        aws s3 cp "symbols/$F" "$S3_BUCKET_SYMBOLS/$ENVIRONMENT/$FINAL_NAME" --no-progress
        if [ $ENVIRONMENT = "production" ]; then
            echo uploading $F to $S3_BUCKET_SYMBOLS/staging/$FINAL_NAME
            aws s3 cp "symbols/$F" "$S3_BUCKET_SYMBOLS/staging/$FINAL_NAME" --no-progress
            echo reseting git staging to production
            git fetch && git checkout staging && git reset origin/production --hard && git push -f origin HEAD
        fi
    done
fi

if [ ${CMD} == 'VALIDATE' ] ; then
    echo validete symbol info
    ENVIRONMENT=${GITHUB_BASE_REF}
    if [[ -z "$(echo 'production staging' | grep -w "$ENVIRONMENT")" ]] ; then
        echo "ERROR: Wrong environment: '$ENVIRONMENT'. It must be 'production' or 'staging'"
        exit 1
    fi
    PR_NUMBER=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")
    git fetch origin --depth=1 > /dev/null 2>&1

    # check for deleted JSON files
    DELETED=$(git diff --name-only --diff-filter=D origin/$ENVIRONMENT)
    if [ -n "$DELETED" ]; then
        echo "### :red_circle: Deleting JSON files is forbidden" > deleted_report
        echo "#### These files were deleted:" >> deleted_report
        echo "$DELETED" >> deleted_report
        DELETED_REPORT=$(cat deleted_report)
        gh pr review $PR_NUMBER -r -b "$DELETED_REPORT"
        exit 1
    fi

    # check for renamed JSON files
    RENAMED=$(git diff --name-only --diff-filter=R origin/$ENVIRONMENT)
    if [ -n "$RENAMED" ]; then
        echo "### :red_circle: Renaming JSON files is forbidden" > renamed_report
        echo "#### These files were renamed:" >> renamed_report
        echo "$RENAMED" >> renamed_report
        RENAMED_REPORT=$(cat renamed_report)
        gh pr review $PR_NUMBER -r -b "$RENAMED_REPORT"
        exit 1
    fi

    # check for added JSON files
    ADDED=$(git diff --name-only --diff-filter=A origin/$ENVIRONMENT)
    if [ -n "$ADDED" ]; then
        echo "### :red_circle: Adding JSON files is forbidden" > added_report
        echo "#### These files were added:" >> added_report
        echo "$ADDED" >> added_report
        ADDED_REPORT=$(cat added_report)
        gh pr review $PR_NUMBER -r -b "$ADDED_REPORT"
        exit 1
    fi

    # validate modified files
    MODIFIED=$(git diff --name-only origin/$ENVIRONMENT | grep ".json$")
    if [ -z "$MODIFIED" ]; then
        echo No symbol info files were modified
        gh pr review $PR_NUMBER -r -b "No symbol info files (JSON) were modified"
        exit 1
    fi
    
    # download inspect tool
    aws s3 cp "$S3_BUCKET_INSPECT/inspect-df-757" ./inspect --no-progress && chmod +x ./inspect
    echo inpsect info: $(./inspect version)

    # save new versions
    for F in $MODIFIED; do
        # !!! custom processing for Kucoin here
        # convert all 'symbol' values to upper case
        cat "$F" | jq '. + {symbol:.symbol|map(ascii_upcase)}' > "$F"
        # commit and push changed files
        git commit -am "fix lowercase symbol names"
        git push origin HEAD
        cp "$F" "$F.new"
    done

    # save old versions
    git checkout -b old origin/$ENVIRONMENT
    for F in $MODIFIED; do cp "$F" "$F.old"; done

    # check files
    FAILED=false

    for F in $MODIFIED; do
        echo Checking "$F"
        ./inspect symfile --old="$F.old" --new="$F.new" --log-file=stdout --report-file=report.txt --report-format=github
        ./inspect symfile diff --old="$F.old" --new="$F.new" --log-file=stdout
        RESULT=$(grep -c FAIL report.txt)
        echo "#### $F" >> full_report.txt
        cat report.txt >> full_report.txt
        [ "$RESULT" -ne 0 ] && FAILED=true
    done

    FULL_REPORT=$(cat full_report.txt)

    [ $FAILED = "true" ] && gh pr review $PR_NUMBER -c -b "$FULL_REPORT" && echo some tests have failed && exit 1
    [ $FAILED = "false" ] && gh pr review $PR_NUMBER -c -b "$FULL_REPORT"

    echo ready to merge

    # merge PR
    # GITHUB_TOKEN=$AUTOMATION_TOKEN
    gh pr merge $PR_NUMBER --merge --delete-branch

fi
