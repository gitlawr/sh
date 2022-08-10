GITLAB_HOME=~/gitlab
sudo docker run --detach \
  --hostname gitlab.lawr.ink \
  --env GITLAB_OMNIBUS_CONFIG="external_url 'https://gitlab.lawr.ink/'; gitlab_rails['lfs_enabled'] = true;" \
  --publish 443:443 --publish 80:80 --publish 8022:22 \
  --restart always \
  --volume $GITLAB_HOME/config:/etc/gitlab \
  --volume $GITLAB_HOME/logs:/var/log/gitlab \
  --volume $GITLAB_HOME/data:/var/opt/gitlab \
  --shm-size 256m \
  gitlab/gitlab-ee:latest
