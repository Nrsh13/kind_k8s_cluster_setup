import org.jenkinsci.plugins.scriptsecurity.scripts.*
ScriptApproval sa = ScriptApproval.get();

//approve classpath
ClasspathEntry cp = new ClasspathEntry("https://digital.artifacts.com/nexustools/0.10.0/nexustools-0.10.0.jar")

sa.configuring(cp, ApprovalContext.create())

for (ScriptApproval.PendingClasspathEntry a : sa.getPendingClasspathEntries()){
  sa.approveClasspathEntry(a.hash)
}

// approve signature
sa.approveSignature("staticMethod com.digital.NexusClient artifactVersions java.util.Map")
