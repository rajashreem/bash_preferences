pkill -9 ruby.
ps aux | grep 'unicorn' | awk '{print $2}' | xargs kill -9

redis-cli flushdb

#cd turnstile && bundle install && bundle exec rake db:migrate && rails s &
#cd customerservice && bundle install && bundle exec rake db:migrate && rails s -p3001 &
cd customerservice && ./script/run_for_test_integration.sh &
#cd legacy_service  && bundle install && bundle exec rake db:reset && bundle exec rake db:migrate && bundle exec rake db:migrate RAILS_ENV=test && bundle exec rails s -p3002 &
cd orders_service  && bundle install && bundle exec rake db:reset && bundle exec rake db:migrate && bundle exec rake db:migrate RAILS_ENV=test && bundle exec rails s -p3004 &
#cd orders_service && bundle install && bundle exec rake db:reset && bundle exec rake db:migrate && bundle exec rake db:migrate RAILS_ENV=test && bundle exec unicorn_rails -c unicorn.conf.minimal.rb -D &
cd payment_service && bundle install && bundle exec rake db:reset && bundle exec rake db:migrate && bundle exec rake db:migrate RAILS_ENV=test && bundle exec rails s -p3005 &
cd competition_management && bundle install && bundle exec rake db:reset && bundle exec rails s -p3006 &
cd entry_service && bundle install && bundle exec rake db:reset && bundle exec rake db:migrate && bundle exec rake db:migrate RAILS_ENV=test && bundle exec rails s -p3007 &
cd communication_service && bundle exec rake db:reset && bundle exec rake db:migrate && bundle exec rake db:migrate RAILS_ENV=test && bundle exec rails s -p3008 &
cd silverpop_mock && bundle install && bundle exec rails s -p9001 &

cd orders_service && bundle exec rake resque:work QUEUE=orders_service &
cd communication_service && bundle exec rake resque:work QUEUE=communication_service &
cd competition_management && bundle exec rake resque:work QUEUE=competition_management &

sleep 5
wget http://localhost:3006
while [ "$?" -ne "0" ]; 
  do
  echo "cant start catalog waiting for comp man"
  wget http://localhost:3006
  sleep 5
done;

echo "Starting catalog"
cd catalog_service && bundle install && bundle exec rake db:reset && bundle exec rake db:migrate && bundle exec rake db:migrate RAILS_ENV=test && bundle exec rails s -p3003 &
