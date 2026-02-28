FROM nginx:alpine
ARG VARIANT=neutral
COPY pages/${VARIANT}.html /usr/share/nginx/html/index.html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
