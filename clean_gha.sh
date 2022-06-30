KEY=""
OWNER=""
REPO=""

curl -H "Accept: application/vnd.github.v3+json" -H "Authorization: token $KEY" https://api.github.com/repos/$OWNER/$REPO/actions/caches?per_page=100 | jq '.actions_caches| .[]|.id'|while read line; do echo "deleting $line";curl -X DELETE -H "Accept: application/vnd.github.v3+json" -H "Authorization: token $KEY" https://api.github.com/repos/$OWNER/$REPO/actions/caches/"$line";echo "deleted"; done
