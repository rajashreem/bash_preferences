pkill -9 ruby

redis-cli flushdb
#cd turnstile && bundle install && bundle exec rake db:migrate && rails s &
#cd customerservice && bundle install && bundle exec rake db:migrate && rails s -p3001 &
cd customerservice && ./script/run_for_test_integration.sh &
cd entry_service && bundle install && bundle exec rake db:reset && rails s -p3007 &
cd legacy_service && bundle install && bundle exec rake db:reset && rails s -p3002 &
cd catalog_service && bundle install && bundle exec rake db:reset && rails s -p3003 &
cd orders_service && bundle install && bundle exec rake db:reset && rails s -p3004 &


cd competition_management && bundle install && bundle exec rake db:reset && rails s -p3006 &
cd payment_service && bundle install && bundle exec rake db:reset && rails s -p3005 &
cd communication_service && bundle install && bundle exec rake db:reset && rails s -p3008 &


cd orders_service && bundle exec rake resque:work QUEUE=orders_service &
