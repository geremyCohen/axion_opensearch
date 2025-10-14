ps -ef | grep -i bench ;ps -ef | grep -o python;sudo pkill -9 -f bench
./dual_installer.sh create delete
./dual_installer.sh create --nodes 16 --shards 16 --heap 80
#rm -rf results/optimization/nyc_taxi_1014_full/


