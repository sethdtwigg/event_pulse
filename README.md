# event_pulse

A Flutter project that will poll the API [https://developer.planning.center/docs/#/overview/] every 5 seconds and will use the following end point to grab the most recent Checked-Out from an Event.
https://api.planningcenteronline.com/check-ins/v2/check_ins?include=event,person,checked_out_by&order=-checked_out_at&where[event_id]=2*****&filter=checked_out&per_page=100
