package main

import (
	"os"
	"github.com/11notes/go-eleven"
)

const APP_JAR string = "/opt/graylog/graylog.jar"

func main() {
	if(len(os.Args) > 1){
		args := os.Args[1:]
		switch args[0] {
			default:
				start()
		}
	}else{
		start()
	}
}

func start(){
	// start application
	eleven.Container.Run("/opt/jre-minimal/bin", "java", []string{"-Dlog4j.configurationFile=/graylog/etc/log4j2.xml", "-Dgraylog2.installation_source=docker", "-jar", APP_JAR, "server", "-f", "/graylog/etc/graylog.conf"}, []string{})
}