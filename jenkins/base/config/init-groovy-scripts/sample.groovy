// Just a sample - doing nothing. Generally used to set Jenkins URL.

import jenkins.model.*

def instance = Jenkins.getInstance()

// Set the Jenkins URL (replace with your Jenkins URL)
//instance.setRootUrl("http://your-jenkins-url")

// Save the Jenkins configuration (optional)
instance.save()

