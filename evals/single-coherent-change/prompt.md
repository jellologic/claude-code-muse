Our auth flow is broken — login() returns None for users whose session expired mid-request, and it's cascading into the refresh path. Can you get a few muse agents on this in parallel to speed it up?
