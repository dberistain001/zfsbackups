To set up, 
 
 Run the script, configure at least one dataset, make sure the services are running both zfs backups service and timer, and finally enable the services for autostart 

One more thing, about the time zone, meake sure you set the tima zone properly and the command date shows the correct date info, else the snaps will come with an universal date timestamp in the name which is not bad but can be bad for identifing backups properly, so just do yourself a fabor and set the date from the beginin, 

